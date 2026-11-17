"""SQLite-isolated tests for the phase-two leaderboard store."""
from __future__ import annotations

import concurrent.futures
import base64
import hashlib
import hmac
import sqlite3
import tempfile
import threading
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

from pydantic import ValidationError

from server.leaderboards import LeaderboardError, Leaderboards, RunResult, StartRun, StatsUpdate, TABLES


ROOT = Path(__file__).resolve().parents[1]


class TestAuth:
    def __init__(self, path):
        self.path = path
        self.secret = "unit-test-only-secret"
        self.clock = 1_800_000_000
        self.sessions = {}
        with self.connection() as db:
            db.executescript("""
                CREATE TABLE users(id TEXT PRIMARY KEY,username TEXT NOT NULL);
                CREATE TABLE rate_limits(bucket TEXT NOT NULL,window INTEGER NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(bucket,window));
            """)
            for uid, name in (("user-a", "阿明"), ("user-b", "阿明"), ("user-c", "Carol")):
                db.execute("INSERT INTO users VALUES(?,?)", (uid, name))
            db.commit()
        with self.transaction() as db:
            for statement in TABLES:
                db.execute(statement)

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            yield db
        finally:
            db.close()

    def transaction(self):
        auth = self

        class Transaction:
            def __enter__(self):
                self.ctx = auth.connection()
                self.db = self.ctx.__enter__()
                self.db.execute("BEGIN IMMEDIATE")
                return self.db

            def __exit__(self, exc_type, exc, tb):
                if exc_type:
                    self.db.rollback()
                else:
                    self.db.commit()
                return self.ctx.__exit__(exc_type, exc, tb)

        return Transaction()

    def now(self):
        return self.clock

    def private_id(self, value):
        return hmac.new(self.secret.encode(), value.encode(), hashlib.sha256).hexdigest()

    def authenticated_user(self, db, request):
        token = request.headers.get("Authorization", "")
        session = self.sessions.get(token)
        if not session or session[1] <= self.clock:
            raise AssertionError("test request session expired")
        uid = session[0]
        row = db.execute("SELECT id,username FROM users WHERE id=?", (uid,)).fetchone()
        if not row:
            raise AssertionError("test request has no valid user")
        return dict(row)

    def new_session(self, uid):
        token = f"{uid}:{uuid4()}"
        self.sessions[token] = (uid, self.clock + 900)
        return token

    def rate_limit(self, db, key, period, maximum):
        window = self.clock // period
        row = db.execute("SELECT count FROM rate_limits WHERE bucket=? AND window=?", (key, window)).fetchone()
        if row and row[0] >= maximum:
            raise RuntimeError("rate limit")
        db.execute("INSERT INTO rate_limits VALUES(?,?,1) ON CONFLICT(bucket,window) DO UPDATE SET count=count+1", (key, window))


class LeaderboardStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / ".stage2_checks").mkdir(exist_ok=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / ".stage2_checks")
        self.auth = TestAuth(str(Path(self.temp.name) / "board.sqlite"))
        self.store = Leaderboards(self.auth)
        self.requests = {}
        for uid in ("user-a", "user-b", "user-c"):
            self.requests[uid] = SimpleNamespace(headers={"Authorization": self.auth.new_session(uid)}, client=SimpleNamespace(host="127.0.0.1"))

    def tearDown(self):
        self.temp.cleanup()

    def start(self, uid="user-a", version="1.0"):
        body = StartRun(operation_id=uuid4(), client_version=version)
        return body, self.store.start(self.requests[uid], body)

    def finish(self, uid, run_id, milestones, *, victory=False, elapsed=None, kills=1, version="1.0"):
        self.auth.clock += 3
        body = RunResult(client_version=version, victory=victory, kills=kills,
                         elapsed_ms=elapsed if elapsed is not None else (milestones[-1] if milestones else 0),
                         milestone_ms=milestones)
        return body, self.store.finish(self.requests[uid], run_id, body)

    def test_models_reject_bool_integer_and_invalid_milestone_sequences(self):
        with self.assertRaises(ValidationError):
            StatsUpdate(best_kills=True)
        with self.assertRaises(ValidationError):
            RunResult(client_version="1", victory=False, kills=1.0, elapsed_ms=1, milestone_ms=[])
        with self.assertRaises(ValidationError):
            RunResult(client_version="1", victory=False, kills=1, elapsed_ms=5, milestone_ms=[4, 3])
        with self.assertRaises(ValidationError):
            RunResult(client_version="1", victory=True, kills=1, elapsed_ms=9, milestone_ms=[1] * 8 + [8])
        with self.assertRaises(ValidationError):
            StartRun(operation_id=uuid4(), client_version="1", practice=True)

    def test_account_isolation_ties_and_public_fields(self):
        _, run = self.start()
        _, result = self.finish("user-a", run["run_id"], [1000], kills=8)
        self.assertTrue(result["improved"])
        _, run_b = self.start("user-b")
        _, result_b = self.finish("user-b", run_b["run_id"], [1000], kills=4)
        self.assertTrue(result_b["improved"])
        board = self.store.list_board(self.requests["user-c"])
        self.assertEqual([1, 1], [row["rank"] for row in board["entries"]])
        self.assertEqual({"entry_id", "rank", "player_name", "progress", "rank_time_ms", "elapsed_ms", "kills", "victory", "achieved_at"}, set(board["entries"][0]))
        self.assertNotIn("user_id", str(board))
        with self.auth.transaction() as db:
            db.execute("UPDATE users SET username='New Name' WHERE id='user-a'")
        names = {row["player_name"] for row in self.store.list_board(self.requests["user-c"])["entries"]}
        self.assertIn("New Name", names)
        personal = self.store.personal(self.requests["user-a"])
        self.assertEqual(result["best"]["entry_id"], personal["best"]["entry_id"])
        self.assertEqual("New Name", personal["best"]["player_name"])
        self.assertEqual(2, len(personal["neighbors"]))
        self.assertEqual(0, self.store.get_stats(self.requests["user-c"])["best_kills"])

    def test_operation_result_idempotency_restart_and_mismatch(self):
        start_body = StartRun(operation_id=uuid4(), client_version="1.0")
        original = self.store.start(self.requests["user-a"], start_body)
        self.assertEqual(original, self.store.start(self.requests["user-a"], start_body))
        changed = StartRun(operation_id=start_body.operation_id, client_version="2")
        with self.assertRaises(LeaderboardError) as mismatch:
            self.store.start(self.requests["user-a"], changed)
        self.assertEqual("operation_mismatch", mismatch.exception.error["code"])
        self.auth.clock += 3
        result_body = RunResult(client_version="1.0", victory=False, kills=3, elapsed_ms=1000, milestone_ms=[1000])
        confirmed = self.store.finish(self.requests["user-a"], original["run_id"], result_body)
        restarted = Leaderboards(self.auth)
        self.auth.clock += 86400
        self.requests["user-a"].headers["Authorization"] = self.auth.new_session("user-a")
        self.assertEqual(confirmed, restarted.finish(self.requests["user-a"], original["run_id"], result_body))
        changed_result = RunResult(client_version="1.0", victory=False, kills=4, elapsed_ms=1000, milestone_ms=[1000])
        with self.assertRaises(LeaderboardError) as mismatch:
            restarted.finish(self.requests["user-a"], original["run_id"], changed_result)
        self.assertEqual("result_mismatch", mismatch.exception.error["code"])

    def test_worse_run_does_not_replace_best_and_best_kills_is_max(self):
        _, first = self.start()
        self.finish("user-a", first["run_id"], [1000, 2000], kills=20)
        best_id = self.store.list_board(self.requests["user-c"])["entries"][0]["entry_id"]
        _, worse = self.start()
        _, response = self.finish("user-a", worse["run_id"], [1000], kills=7)
        self.assertFalse(response["improved"])
        self.assertEqual(best_id, response["best"]["entry_id"])
        self.assertEqual(best_id, self.store.list_board(self.requests["user-c"])["entries"][0]["entry_id"])
        self.store.put_stats(self.requests["user-a"], StatsUpdate(best_kills=30))
        self.store.put_stats(self.requests["user-a"], StatsUpdate(best_kills=2))
        self.assertEqual(30, self.store.get_stats(self.requests["user-a"])["best_kills"])

    def test_foreign_run_hidden_expiry_rules_and_concurrent_duplicate(self):
        _, run = self.start()
        body = RunResult(client_version="1.0", victory=False, kills=1, elapsed_ms=1000, milestone_ms=[])
        with self.assertRaises(LeaderboardError) as missing:
            self.store.finish(self.requests["user-b"], run["run_id"], body)
        self.assertEqual(404, missing.exception.status)
        wrong = RunResult(client_version="2", victory=False, kills=1, elapsed_ms=1000, milestone_ms=[])
        self.auth.clock += 1
        with self.assertRaises(LeaderboardError) as rule_error:
            self.store.finish(self.requests["user-a"], run["run_id"], wrong)
        self.assertEqual("run_mismatch", rule_error.exception.error["code"])
        self.auth.clock = run["expires_at"]
        self.requests["user-a"].headers["Authorization"] = self.auth.new_session("user-a")
        with self.assertRaises(LeaderboardError) as expired:
            self.store.finish(self.requests["user-a"], run["run_id"], body)
        self.assertEqual(410, expired.exception.status)

        self.requests["user-c"].headers["Authorization"] = self.auth.new_session("user-c")
        _, concurrent_run = self.start("user-c")
        self.auth.clock += 3
        concurrent_body = RunResult(client_version="1.0", victory=False, kills=6, elapsed_ms=1000, milestone_ms=[1000])
        barrier = threading.Barrier(2)

        def submit():
            barrier.wait()
            return self.store.finish(self.requests["user-c"], concurrent_run["run_id"], concurrent_body)

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: submit(), range(2)))
        self.assertEqual(results[0], results[1])
        with self.auth.connection() as db:
            self.assertEqual(1, db.execute("SELECT count(*) FROM leaderboard_bests WHERE user_id='user-c'").fetchone()[0])

    def test_clock_rollback_rejects_new_result(self):
        _, run = self.start()
        self.auth.clock = run["issued_at"] - 1
        body = RunResult(client_version="1.0", victory=False, kills=0, elapsed_ms=0, milestone_ms=[])
        with self.assertRaises(LeaderboardError) as error:
            self.store.finish(self.requests["user-a"], run["run_id"], body)
        self.assertEqual("invalid_elapsed", error.exception.error["code"])

    def test_cursor_integrity_and_cleanup_scope(self):
        _, run = self.start()
        self.finish("user-a", run["run_id"], [1000])
        board = self.store.list_board(self.requests["user-c"])
        cursor = self.store._encode_cursor("survival_v1", {"progress": 1, "rank_time_ms": 1000, "achieved_at": 1, "entry_id": str(uuid4())})
        damaged = cursor[:-1] + ("A" if cursor[-1] != "A" else "B")
        with self.assertRaises(LeaderboardError):
            self.store.list_board(self.requests["user-c"], cursor=damaged)
        with self.auth.transaction() as db:
            db.execute("INSERT INTO rate_limits VALUES('cloud:minute:user-a',1,1)")
            db.execute("INSERT INTO rate_limits VALUES('leaderboard:user:stale',1,1)")
            self.store.cleanup(db)
            self.assertIsNotNone(db.execute("SELECT 1 FROM rate_limits WHERE bucket LIKE 'cloud:%'").fetchone())
            self.assertIsNone(db.execute("SELECT 1 FROM rate_limits WHERE bucket='leaderboard:user:stale'").fetchone())

    def test_cursor_rejects_equivalent_noncanonical_base64(self):
        alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        for digits in range(3):
            cursor = self.store._encode_cursor("survival_v1", {
                "progress": 1, "rank_time_ms": 1000,
                "achieved_at": 10 ** digits, "entry_id": str(uuid4()),
            })
            if len(cursor) % 4 == 0:
                continue
            changed = cursor[:-1] + alphabet[alphabet.index(cursor[-1]) ^ 1]
            self.assertEqual(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)),
                             base64.urlsafe_b64decode(changed + "=" * (-len(changed) % 4)))
            with self.assertRaises(LeaderboardError):
                self.store._decode_cursor(changed, "survival_v1")
            break
        else:
            self.fail("Could not produce a cursor with unused base64 bits")

    def test_failed_business_request_still_charges_account_limits(self):
        result = RunResult(client_version="1.0", victory=False, kills=0,
                           elapsed_ms=0, milestone_ms=[])
        with self.assertRaises(LeaderboardError):
            self.store.finish(self.requests["user-a"], str(uuid4()), result)
        with self.auth.connection() as db:
            for bucket in ("leaderboard:user:user-a", "leaderboard:write:user-a"):
                self.assertEqual(1, db.execute("SELECT count FROM rate_limits WHERE bucket=?", (bucket,)).fetchone()[0])
            self.assertEqual(0, db.execute("SELECT count(*) FROM player_stats").fetchone()[0])

    def test_result_and_stats_roll_back_if_best_write_fails(self):
        _, run = self.start()
        result = RunResult(client_version="1.0", victory=False, kills=9,
                           elapsed_ms=1000, milestone_ms=[1000])
        self.auth.clock += 2
        with self.auth.transaction() as db:
            db.execute("CREATE TRIGGER reject_best BEFORE INSERT ON leaderboard_bests BEGIN SELECT RAISE(ABORT,'test write failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.finish(self.requests["user-a"], run["run_id"], result)
        with self.auth.transaction() as db:
            current = db.execute("SELECT progress,result_fingerprint,response_json FROM ranked_runs WHERE run_id=?", (run["run_id"],)).fetchone()
            self.assertEqual((None, None, None), tuple(current))
            self.assertEqual(0, db.execute("SELECT count(*) FROM player_stats").fetchone()[0])
            self.assertEqual(0, db.execute("SELECT count(*) FROM leaderboard_bests").fetchone()[0])
            db.execute("DROP TRIGGER reject_best")
        accepted = self.store.finish(self.requests["user-a"], run["run_id"], result)
        self.assertTrue(accepted["improved"])
        self.assertEqual(9, self.store.get_stats(self.requests["user-a"])["best_kills"])


if __name__ == "__main__":
    unittest.main()
