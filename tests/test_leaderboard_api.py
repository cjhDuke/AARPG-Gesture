"""Isolated HTTP, migration, and compatibility regressions for leaderboard stage 2."""

from __future__ import annotations

import asyncio
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient
from request_limits import RequestLimits  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "server"
if str(SERVER) not in sys.path:
    sys.path.insert(0, str(SERVER))

from app import AuthService, CodeRequest, LoginRequest, RegisterRequest, SCHEMA, Settings, VerifyRequest, create_app  # noqa: E402
from cloud_saves import Mutation, PutSave  # noqa: E402

# The Windows Proactor loop's socketpair setup can block in restricted test hosts.
if os.name == "nt":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


class MutableClock:
    def __init__(self, value=1_800_000_000):
        self.value = value

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += seconds


class LeaderboardApiTests(unittest.TestCase):
    def setUp(self):
        check_root = ROOT / ".stage2_checks"
        check_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=check_root)
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "accounts.sqlite3"
        self.clock = MutableClock()
        self.delivered = []

        def sender(email, purpose, code, challenge):
            self.delivered.append((email, purpose, code, challenge))
            return "memory-message"

        secret = os.urandom(48).hex()
        self.settings = Settings(database=self.path, secret=secret)
        self.app = create_app(self.settings, sender=sender, clock=self.clock)
        self.client = TestClient(self.app, client=("stage2-isolated-client", 53124))
        self.addCleanup(self.client.close)
        self.service: AuthService = self.app.state.auth
        self.users = {}
        self.tokens = {}
        self.add_user("a", "阿青")
        self.add_user("b", "阿青")

    def add_user(self, key, username):
        user_id = str(uuid.uuid4())
        email = f"{key}-{uuid.uuid4().hex[:8]}@example.test"
        with self.service.transaction() as db:
            db.execute("INSERT INTO users(id,email,password_hash,created_at,username) VALUES(?,?,?,?,?)",
                       (user_id, email, "test-hash-not-used", self.service.now(), username))
            row = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
            session = self.service.new_session(db, row)
        self.users[key] = {"id": user_id, "email": email, "username": username}
        self.tokens[key] = session["access_token"]

    def auth(self, key="a"):
        return {"Authorization": "Bearer " + self.tokens[key]}

    def start(self, key="a", operation=None, **changes):
        body = {"operation_id": str(operation or uuid.uuid4()), "ruleset_id": "survival_v1", "client_version": "1.0"}
        body.update(changes)
        response = self.client.post("/api/v1/ranked-runs", json=body, headers=self.auth(key))
        return response, body

    def finish(self, run_id, *, key="a", milestones=None, victory=False, elapsed_ms=None, kills=3,
               advance_clock=True, **changes):
        milestones = milestones if milestones is not None else [1000, 2000]
        elapsed_ms = elapsed_ms if elapsed_ms is not None else (milestones[-1] if milestones else 0)
        if advance_clock and elapsed_ms:
            self.clock.advance((elapsed_ms + 999) // 1000)
        body = {"ruleset_id": "survival_v1", "client_version": "1.0", "victory": victory,
                "kills": kills, "elapsed_ms": elapsed_ms, "milestone_ms": milestones}
        body.update(changes)
        return self.client.put(f"/api/v1/ranked-runs/{run_id}/result", json=body, headers=self.auth(key)), body

    def create_result(self, *, key="a", milestones=(1000, 2000), victory=False, kills=3, **changes):
        response, _ = self.start(key)
        self.assertEqual(response.status_code, 201, response.text)
        return self.finish(response.json()["run_id"], key=key, milestones=list(milestones), victory=victory,
                           kills=kills, **changes)[0]

    def test_public_board_is_anonymous_and_public_rows_are_private(self):
        self.assertEqual(self.create_result().status_code, 200)
        response = self.client.get("/api/v1/leaderboards", params={"ruleset_id": "survival_v1"})
        self.assertEqual(response.status_code, 200, response.text)
        data = response.json()
        self.assertEqual(data["ruleset_id"], "survival_v1")
        self.assertIn("rules", data)
        self.assertIn("generated_at", data)
        self.assertIsInstance(data["entries"], list)
        forbidden = {"email", "user_id", "token", "run_id", "operation_id"}
        for row in data["entries"]:
            self.assertTrue({"entry_id", "rank", "player_name", "progress", "rank_time_ms", "elapsed_ms",
                             "kills", "victory", "achieved_at"} <= row.keys())
            self.assertFalse(forbidden & row.keys())
            self.assertNotIn(self.users["a"]["email"], json.dumps(row))

    def test_auth_missing_invalid_and_cross_account_run_theft(self):
        body = {"operation_id": str(uuid.uuid4()), "ruleset_id": "survival_v1", "client_version": "1.0"}
        self.assertIn(self.client.post("/api/v1/ranked-runs", json=body).status_code, (401, 403))
        started, _ = self.start("a")
        self.assertEqual(started.status_code, 201, started.text)
        run = started.json()["run_id"]
        denied, _ = self.finish(run, key="b")
        self.assertIn(denied.status_code, (403, 404))

    def test_start_idempotency_and_operation_payload_conflict(self):
        op = str(uuid.uuid4())
        first, _ = self.start(operation=op)
        again, _ = self.start(operation=op)
        self.assertEqual(first.status_code, 201, first.text)
        self.assertEqual(again.status_code, 201, again.text)
        self.assertEqual(first.json(), again.json())
        conflict, _ = self.start(operation=op, client_version="2.0")
        self.assertEqual(conflict.status_code, 409)

    def test_start_rejects_wrong_versions_flags_and_unknown_fields(self):
        cases = ({"ruleset_id": "other"}, {"client_version": "has space"}, {"continued": True},
                 {"practice": True}, {"debug_used": True}, {"user_id": self.users["a"]["id"]})
        for change in cases:
            with self.subTest(change=change):
                response, _ = self.start(**change)
                self.assertIn(response.status_code, (400, 409, 422))
        for version in ("中文", "v" * 33):
            response, _ = self.start(client_version=version)
            self.assertIn(response.status_code, (400, 409, 422))
        valid, _ = self.start(client_version="0.9")
        self.assertEqual(valid.status_code, 201, valid.text)

    def test_finish_rejects_client_version_different_from_start(self):
        started, _ = self.start(client_version="0.9")
        self.assertEqual(started.status_code, 201, started.text)
        response, _ = self.finish(started.json()["run_id"], milestones=[500], client_version="1.0")
        self.assertEqual(response.status_code, 409, response.text)

    def test_start_response_has_contract_and_uuid(self):
        response, _ = self.start()
        self.assertEqual(response.status_code, 201, response.text)
        data = response.json()
        uuid.UUID(data["run_id"])
        self.assertEqual(data["ruleset_id"], "survival_v1")
        self.assertEqual(data["client_version"], "1.0")
        self.assertTrue({"issued_at", "expires_at", "server_time"} <= data.keys())

    def test_finish_progress_is_server_computed_and_best_improves_only_for_better_runs(self):
        response = self.create_result(milestones=(1000, 2000, 3000), kills=99)
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        self.assertEqual(result["progress"], 3)
        self.assertTrue(result["improved"])
        best = result["best"]
        self.assertEqual(best["progress"], 3)
        self.assertEqual(best["kills"], 99)
        worse = self.create_result(milestones=(1000, 2100), kills=999)
        self.assertEqual(worse.status_code, 200, worse.text)
        self.assertFalse(worse.json()["improved"])
        self.assertEqual(worse.json()["best"]["kills"], 99)
        tied = self.create_result(milestones=(1000, 2000), kills=1)
        self.assertFalse(tied.json()["improved"])
        self.assertEqual(tied.json()["best"]["kills"], 99)

    def test_finish_replay_survives_restart_and_mismatch_conflicts(self):
        started, _ = self.start()
        run = started.json()["run_id"]
        first, payload = self.finish(run, milestones=[500])
        self.assertEqual(first.status_code, 200, first.text)
        replay = self.client.put(f"/api/v1/ranked-runs/{run}/result", json=payload, headers=self.auth())
        self.assertEqual(replay.status_code, 200, replay.text)
        self.assertEqual(replay.json(), first.json())
        changed = dict(payload, kills=4)
        conflict = self.client.put(f"/api/v1/ranked-runs/{run}/result", json=changed, headers=self.auth())
        self.assertEqual(conflict.status_code, 409)
        restarted_app = create_app(self.settings, sender=lambda *_: "memory-message", clock=self.clock)
        restarted = TestClient(restarted_app)
        self.addCleanup(restarted.close)
        persisted = restarted.put(f"/api/v1/ranked-runs/{run}/result", json=payload, headers=self.auth())
        self.assertEqual(persisted.status_code, 200, persisted.text)
        self.assertEqual(persisted.json(), first.json())

    def test_expired_unsettled_run_is_gone_but_previously_settled_replay_is_valid(self):
        started, _ = self.start()
        run = started.json()["run_id"]
        first, body = self.finish(run, milestones=[500])
        self.assertEqual(first.status_code, 200, first.text)
        started2, _ = self.start()
        self.clock.advance(24 * 3600 + 1)
        self._issue_access_token("a")
        expired, _ = self.finish(started2.json()["run_id"], milestones=[1000])
        self.assertEqual(expired.status_code, 410)
        replay = self.client.put(f"/api/v1/ranked-runs/{run}/result", json=body, headers=self.auth())
        self.assertEqual(replay.status_code, 200, replay.text)
        self.assertEqual(replay.json(), first.json())

    def test_result_rejects_payloads_outside_rules(self):
        invalid = [
            {"victory": True, "milestone_ms": [1], "elapsed_ms": 1},
            {"victory": False, "milestone_ms": list(range(1, 10)), "elapsed_ms": 9},
            {"milestone_ms": [2, 1], "elapsed_ms": 2},
            {"milestone_ms": [1, 3], "elapsed_ms": 2},
            {"milestone_ms": [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], "elapsed_ms": 1},
            {"milestone_ms": [1], "victory": "false"},
            {"milestone_ms": [1], "elapsed_ms": True},
            {"milestone_ms": [1], "kills": "1"},
            {"milestone_ms": [1], "kills": 1.5},
            {"milestone_ms": [1], "ruleset_id": "other"},
            {"milestone_ms": [1], "continued": True},
            {"milestone_ms": [1], "practice": True},
            {"milestone_ms": [1], "debug_used": True},
            {"milestone_ms": [1], "surprise": 1},
        ]
        for fields in invalid:
            with self.subTest(fields=fields):
                self.clock.advance(60)
                started, _ = self.start()
                response, _ = self.finish(started.json()["run_id"], milestones=[1000], **fields)
                self.assertIn(response.status_code, (400, 409, 422))

    def test_numeric_bounds_and_nonfinite_json_are_rejected_without_echo(self):
        for invalid_number in ("NaN", "Infinity", "-Infinity"):
            raw = ('{"ruleset_id":"survival_v1","client_version":"1.0",'
                   '"victory":false,"kills":1,"milestone_ms":[1000],'
                   '"elapsed_ms":' + invalid_number + '}').encode()
            started, _ = self.start()
            self.assertEqual(started.status_code, 201, started.text)
            response = self.client.put(f"/api/v1/ranked-runs/{started.json()['run_id']}/result", content=raw,
                                       headers={**self.auth(), "Content-Type": "application/json"})
            self.assertEqual(response.status_code, 422)
            self.assertEqual(response.json()["error"]["code"], "invalid_leaderboard_request")
            self.assertNotIn(invalid_number, response.text)
        for value in (-1, 2**31, 1.1, True):
            self.clock.advance(60)
            started, _ = self.start()
            response, _ = self.finish(started.json()["run_id"], milestones=[1000], kills=value)
            self.assertIn(response.status_code, (400, 422))

    def test_time_cap_matches_server_observation_with_one_second_tolerance(self):
        started, _ = self.start()
        run = started.json()["run_id"]
        self.clock.advance(5)
        accepted, _ = self.finish(run, milestones=[6000], elapsed_ms=6000, advance_clock=False)
        self.assertEqual(accepted.status_code, 200, accepted.text)
        started, _ = self.start()
        rejected, _ = self.finish(started.json()["run_id"], milestones=[7001], elapsed_ms=7001, advance_clock=False)
        self.assertIn(rejected.status_code, (400, 422))

    def test_server_clock_before_issued_at_rejects_result(self):
        started, _ = self.start()
        self.clock.advance(-1)
        response, _ = self.finish(started.json()["run_id"], milestones=[], elapsed_ms=0, advance_clock=False)
        self.assertEqual(response.status_code, 422, response.text)
        self.assertEqual(response.json()["error"]["code"], "invalid_elapsed")

    def test_concurrent_same_run_submission_is_idempotent_and_best_is_atomic(self):
        started, _ = self.start()
        run = started.json()["run_id"]
        payload = {"ruleset_id": "survival_v1", "client_version": "1.0", "victory": False,
                   "kills": 7, "elapsed_ms": 800, "milestone_ms": [800]}

        def send(run_id, body):
            return self.client.put(f"/api/v1/ranked-runs/{run_id}/result", json=body, headers=self.auth())

        with ThreadPoolExecutor(max_workers=2) as pool:
            same = list(pool.map(lambda _: send(run, payload), range(2)))
        self.assertEqual([item.status_code for item in same], [200, 200])
        self.assertEqual(same[0].json(), same[1].json())

        first, _ = self.start()
        second, _ = self.start()
        self.clock.advance(2)
        submissions = [
            (first.json()["run_id"], {"ruleset_id": "survival_v1", "client_version": "1.0", "victory": False,
                                       "kills": 1, "elapsed_ms": 1200, "milestone_ms": [500, 1200]}),
            (second.json()["run_id"], {"ruleset_id": "survival_v1", "client_version": "1.0", "victory": False,
                                        "kills": 2, "elapsed_ms": 900, "milestone_ms": [300, 900, 900]}),
        ]
        with ThreadPoolExecutor(max_workers=2) as pool:
            distinct = list(pool.map(lambda item: send(item[0], item[1]), submissions))
        self.assertEqual([item.status_code for item in distinct], [200, 200])
        best = self.client.get("/api/v1/me/leaderboard", params={"ruleset_id": "survival_v1"}, headers=self.auth()).json()["best"]
        self.assertEqual((best["progress"], best["rank_time_ms"]), (3, 900))

    def test_personal_board_name_updates_and_neighbors(self):
        self.create_result()
        response = self.client.get("/api/v1/me/leaderboard", params={"ruleset_id": "survival_v1"}, headers=self.auth())
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["best"]["player_name"], "阿青")
        changed = self.client.patch("/api/v1/me", json={"username": "新名字"}, headers=self.auth())
        self.assertEqual(changed.status_code, 200, changed.text)
        response = self.client.get("/api/v1/leaderboards", params={"ruleset_id": "survival_v1"})
        self.assertIn("新名字", [row["player_name"] for row in response.json()["entries"]])
        me = self.client.get("/api/v1/me/leaderboard", params={"ruleset_id": "survival_v1"}, headers=self.auth()).json()
        self.assertIn("neighbors", me)
        self.assertNotIn(self.users["a"]["email"], json.dumps(me))

    def test_pagination_page_size_cross_page_ties_and_global_rank(self):
        # Distinct accounts are unnecessary for rows only if service permits one best per account;
        # seed isolated authenticated accounts to exercise 22+ independently ranked identities.
        for i in range(22):
            key = f"page{i}"
            self.add_user(key, f"玩家{i}")
            result = self.create_result(key=key, milestones=(1000,), kills=i)
            self.assertEqual(result.status_code, 200, result.text)
        first = self.client.get("/api/v1/leaderboards", params={"ruleset_id": "survival_v1"}).json()
        self.assertEqual(len(first["entries"]), 20)
        self.assertIsNotNone(first["next_cursor"])
        second_response = self.client.get("/api/v1/leaderboards", params={"ruleset_id": "survival_v1", "cursor": first["next_cursor"]})
        self.assertEqual(second_response.status_code, 200, second_response.text)
        second = second_response.json()
        self.assertGreaterEqual(len(second["entries"]), 2)
        self.assertEqual([r["rank"] for r in first["entries"] + second["entries"]], [1] * 22)
        tampered = self.client.get("/api/v1/leaderboards", params={"ruleset_id": "survival_v1", "cursor": first["next_cursor"] + "x"})
        self.assertIn(tampered.status_code, (400, 422))
        huge = self.client.get("/api/v1/leaderboards", params={"ruleset_id": "survival_v1", "cursor": "x" * 10000})
        self.assertIn(huge.status_code, (400, 422))
        cross = self.client.get("/api/v1/leaderboards", params={"ruleset_id": "other", "cursor": first["next_cursor"]})
        self.assertIn(cross.status_code, (400, 422))

    def test_stats_max_merge_restart_and_user_isolation(self):
        for key, value, expected in (("a", 25, 25), ("a", 9, 25), ("b", 12, 12)):
            response = self.client.put("/api/v1/me/stats", json={"best_kills": value}, headers=self.auth(key))
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["best_kills"], expected)
            self.assertIn("updated_at", response.json())
            self.assertIn("server_time", response.json())
        restarted_app = create_app(self.settings, sender=lambda *_: "memory-message", clock=self.clock)
        restarted = TestClient(restarted_app)
        self.addCleanup(restarted.close)
        for key, expected in (("a", 25), ("b", 12)):
            response = restarted.get("/api/v1/me/stats", headers=self.auth(key))
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["best_kills"], expected)
        for bad in (True, "7", 3.2, -1, 2**31):
            response = self.client.put("/api/v1/me/stats", json={"best_kills": bad}, headers=self.auth())
            self.assertIn(response.status_code, (400, 422))

    def test_rate_limits_have_retry_after_and_are_auth_scoped(self):
        # Separate accounts must not consume one another's account quota.
        start = self.client.post("/api/v1/ranked-runs", json={"operation_id": str(uuid.uuid4()), "ruleset_id": "survival_v1", "client_version": "1.0"}, headers=self.auth("a"))
        self.assertEqual(start.status_code, 201, start.text)
        # Repeated writes eventually trip one of the specified per-account buckets.
        hit = None
        for _ in range(130):
            response = self.client.put("/api/v1/me/stats", json={"best_kills": 0}, headers=self.auth("a"))
            if response.status_code == 429:
                hit = response
                break
        self.assertIsNotNone(hit, "expected account write rate limit")
        self.assertTrue(hit.headers.get("Retry-After"))
        other = self.client.put("/api/v1/me/stats", json={"best_kills": 0}, headers=self.auth("b"))
        self.assertEqual(other.status_code, 200, other.text)

    def test_ingress_quota_survives_service_restart(self):
        bucket = "leaderboard:ingress:" + self.service.private_id("stage2-isolated-client")
        with self.service.transaction() as db:
            db.execute("INSERT INTO rate_limits(bucket,window,count) VALUES(?,?,300)",
                       (bucket, self.service.now() // 60))
        restarted_app = create_app(self.settings, sender=lambda *_: "memory", clock=self.clock)
        with TestClient(restarted_app, client=("stage2-isolated-client", 53124)) as restarted:
            response = restarted.get("/api/v1/leaderboards")
            self.assertEqual(response.status_code, 429, response.text)
            self.assertTrue(response.headers.get("Retry-After"))
            self.assertEqual(restarted.get("/api/v1/health").status_code, 200)

    def test_request_limits_reject_forged_lengths_and_chunked_overflow(self):
        async def invoke(headers, messages):
            received = iter(messages)
            output = []

            async def receive():
                return next(received)

            async def send(message):
                output.append(message)

            async def downstream(_scope, _receive, send_inner):
                await send_inner({"type": "http.response.start", "status": 200, "headers": []})
                await send_inner({"type": "http.response.body", "body": b"ok"})

            middleware = RequestLimits(downstream)
            await middleware({"type": "http", "method": "POST", "path": "/api/v1/ranked-runs", "headers": headers}, receive, send)
            return output

        async def checks():
            oversized_length = await invoke([(b"content-length", b"8193"), (b"content-type", b"application/json")], [])
            self.assertEqual(oversized_length[0]["status"], 413)
            self.assertIn((b"cache-control", b"no-store"), oversized_length[0]["headers"])
            dishonest = await invoke([(b"content-length", b"10"), (b"content-type", b"application/json")],
                                     [{"type": "http.request", "body": b"x" * 4096, "more_body": True},
                                      {"type": "http.request", "body": b"x" * 4097, "more_body": False}])
            self.assertEqual(dishonest[0]["status"], 413)
            mismatch = await invoke([(b"content-length", b"9"), (b"content-type", b"application/json")],
                                    [{"type": "http.request", "body": b"{}", "more_body": False}])
            self.assertEqual(mismatch[0]["status"], 400)

        asyncio.run(checks())

    def test_ingress_counter_persists_invalid_attempt_before_validation(self):
        bucket = "leaderboard:ingress:" + self.service.private_id("stage2-isolated-client")
        with self.service.transaction() as db:
            db.execute("INSERT INTO rate_limits(bucket,window,count) VALUES(?,?,299)", (bucket, self.service.now() // 60))
        bad = self.client.post("/api/v1/ranked-runs", content=b"{", headers={"Content-Type": "application/json"})
        self.assertEqual(bad.status_code, 422, bad.text)
        self.assertEqual(bad.json()["error"]["code"], "invalid_leaderboard_request")
        limited = self.client.get("/api/v1/leaderboards")
        self.assertEqual(limited.status_code, 429, limited.text)
        self.assertTrue(limited.headers.get("Retry-After"))
        self.assertEqual(limited.headers.get("Cache-Control"), "no-store")
        self.assertEqual(limited.headers.get("X-Content-Type-Options"), "nosniff")
        self.assertEqual(self.client.get("/api/v1/health").status_code, 200)

    def test_http_body_limits_preserve_account_and_cloud_upload_sizes(self):
        headers = {"Content-Type": "application/json"}
        oversized_stats = b'{"best_kills":"' + b"x" * 8200 + b'"}'
        too_large = self.client.put("/api/v1/me/stats", content=oversized_stats, headers=headers)
        self.assertEqual(too_large.status_code, 413)
        mismatch = self.client.put("/api/v1/me/stats", content=b"{}",
                                   headers={**headers, "Content-Length": "9"})
        self.assertEqual(mismatch.status_code, 400)
        false_length = self.client.put("/api/v1/me/stats", content=oversized_stats,
                                       headers={**headers, "Content-Length": "2"})
        self.assertEqual(false_length.status_code, 413)
        wrong_type = self.client.put("/api/v1/me/stats", content=b"{}",
                                     headers={"Content-Type": "text/plain"})
        self.assertEqual(wrong_type.status_code, 415)
        save_id = uuid.uuid4().hex
        cloud_body = {"base_revision": 0, "operation_id": str(uuid.uuid4()), "device_id": str(uuid.uuid4()),
                      "record": {"name": "x" * 9000}}
        cloud_raw = json.dumps(cloud_body).encode("utf-8")
        self.assertGreater(len(cloud_raw), 8192)
        self.assertLess(len(cloud_raw), 80 * 1024)
        cloud = self.client.put(f"/api/v1/saves/{save_id}", content=cloud_raw, headers=headers)
        self.assertEqual(cloud.status_code, 422, cloud.text)
        self.assertEqual(cloud.json()["error"]["code"], "invalid_save")

    def test_existing_auth_and_cloud_save_flows_remain_compatible(self):
        self.assertEqual(self.client.get("/api/v1/me", headers=self.auth()).status_code, 200)
        refreshed = self.client.post("/api/v1/auth/refresh", json={"refresh_token": self._refresh_token("a")})
        self.assertEqual(refreshed.status_code, 200, refreshed.text)
        self.tokens["a"] = refreshed.json()["access_token"]
        self.assertEqual(self.client.patch("/api/v1/me", json={"username": "改名测试"}, headers=self.auth()).status_code, 200)
        save_id, operation, device = uuid.uuid4().hex, str(uuid.uuid4()), str(uuid.uuid4())
        record = self._valid_save(save_id)
        body = {"base_revision": 0, "operation_id": operation, "device_id": device, "record": record}
        put = self.client.put(f"/api/v1/saves/{save_id}", json=body, headers=self.auth())
        self.assertEqual(put.status_code, 200, put.text)
        loaded = self.client.get(f"/api/v1/saves/{save_id}", headers=self.auth())
        self.assertEqual(loaded.status_code, 200, loaded.text)
        self.assertEqual(json.loads(loaded.json()["record_json"])["id"], save_id)
        conflict = dict(body, operation_id=str(uuid.uuid4()), base_revision=0)
        self.assertEqual(self.client.put(f"/api/v1/saves/{save_id}", json=conflict, headers=self.auth()).status_code, 409)
        deletion = {"base_revision": 1, "operation_id": str(uuid.uuid4()), "device_id": device}
        self.assertEqual(self.client.request("DELETE", f"/api/v1/saves/{save_id}", json=deletion, headers=self.auth()).status_code, 200)
        self.assertEqual(self.client.post("/api/v1/auth/logout", json={"refresh_token": refreshed.json()["refresh_token"]}).status_code, 200)
        self.assertIn(self.client.get("/api/v1/me", headers=self.auth()).status_code, (401, 403))

    def test_register_login_and_password_reset_use_only_memory_delivery(self):
        email = f"new-{uuid.uuid4().hex[:10]}@example.com"

        def issue(purpose):
            code_response = self.client.post("/api/v1/auth/email-codes", json={"email": email, "purpose": purpose})
            self.assertEqual(code_response.status_code, 202, code_response.text)
            self.service.deliver_pending()
            self.assertTrue(self.delivered)
            sent_email, sent_purpose, code, challenge = self.delivered[-1]
            self.assertEqual((sent_email, sent_purpose), (email, purpose))
            return code, challenge

        code, challenge = issue("register")
        registration = self.client.post("/api/v1/auth/register", json={
            "email": email, "password": "StageTwoPasswordOne9!", "username": "测试玩家",
            "challenge_id": challenge, "code": code,
        })
        self.assertEqual(registration.status_code, 201, registration.text)
        login = self.client.post("/api/v1/auth/login", json={"email": email, "password": "StageTwoPasswordOne9!"})
        self.assertEqual(login.status_code, 200, login.text)
        self.clock.advance(60)
        reset_code, reset_challenge = issue("reset")
        reset = self.client.post("/api/v1/auth/password-reset", json={
            "email": email, "password": "StageTwoPasswordTwo9!", "challenge_id": reset_challenge, "code": reset_code,
        })
        self.assertEqual(reset.status_code, 200, reset.text)
        stale = self.client.get("/api/v1/me", headers={"Authorization": "Bearer " + login.json()["access_token"]})
        self.assertIn(stale.status_code, (401, 403))
        old_password = self.client.post("/api/v1/auth/login", json={"email": email, "password": "StageTwoPasswordOne9!"})
        self.assertEqual(old_password.status_code, 401)
        old_access = login.json()["access_token"]
        stale = self.client.get("/api/v1/me", headers={"Authorization": "Bearer " + old_access})
        self.assertIn(stale.status_code, (401, 403))
        old_password = self.client.post("/api/v1/auth/login", json={"email": email, "password": "Stage2Pass2026!"})
        self.assertEqual(old_password.status_code, 401)
        self.assertEqual(self.client.post("/api/v1/auth/login", json={"email": email, "password": "StageTwoPasswordTwo9!"}).status_code, 200)
        self.assertEqual(self.client.post("/api/v1/auth/logout", json={"refresh_token": login.json()["refresh_token"]}).status_code, 200)

    def _refresh_token(self, key):
        with self.service.connection() as db:
            row = db.execute("SELECT refresh_hash FROM sessions WHERE user_id=? ORDER BY rowid DESC LIMIT 1", (self.users[key]["id"],)).fetchone()
        # The token is intentionally not recoverable from its hash; tests use a fresh real session instead.
        with self.service.transaction() as db:
            user = db.execute("SELECT * FROM users WHERE id=?", (self.users[key]["id"],)).fetchone()
            session = self.service.new_session(db, user)
        self._refreshes = getattr(self, "_refreshes", {})
        self._refreshes[key] = session["refresh_token"]
        self.tokens[key] = session["access_token"]
        return self._refreshes[key]

    def _issue_access_token(self, key):
        with self.service.transaction() as db:
            user = db.execute("SELECT * FROM users WHERE id=?", (self.users[key]["id"],)).fetchone()
            session = self.service.new_session(db, user)
        self.tokens[key] = session["access_token"]

    @staticmethod
    def _valid_save(save_id):
        return {"version": 2, "id": save_id, "name": "回归档", "created_at": "2026-11-17 10:00:00",
                "saved_at": "2026-11-17 10:00:00", "saved_unix": 1800000000,
                "checkpoint": {"stage": 0, "stage_name": "DUNGEON", "kind": "waves", "wave": 1,
                               "hp": 6, "psi": 0, "upgrades": {}, "kills": 0,
                               "loot": {"bag_apples": 0, "picked": [0, 0, 0], "kills_since_apple": 0, "eat_timer": 0}}}


class MigrationTests(unittest.TestCase):
    def setUp(self):
        base = ROOT / ".stage2_checks"
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.temp.cleanup)

    def _legacy_db(self, version):
        path = Path(self.temp.name) / f"schema{version}.sqlite3"
        user_id = str(uuid.uuid4())
        with closing(sqlite3.connect(path)) as connection, connection as db:
            db.executescript(SCHEMA)  # Baseline SCHEMA creates the schema_version=1 marker itself.
            if version >= 2:
                db.execute("ALTER TABLE users ADD COLUMN username TEXT NOT NULL DEFAULT ''")
                db.execute("INSERT INTO users(id,email,password_hash,created_at,username) VALUES(?,?,?,?,?)",
                           (user_id, f"legacy-{version}@example.com", "retained-password-hash", 1700000000, "旧玩家"))
            else:
                db.execute("INSERT INTO users(id,email,password_hash,created_at) VALUES(?,?,?,?)",
                           (user_id, f"legacy-{version}@example.com", "retained-password-hash", 1700000000))
            db.execute("UPDATE schema_version SET version=?", (version,))
            db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?)", (str(uuid.uuid4()), user_id, "access-hash", "refresh-hash", 1900000000, 2000000000))
            from cloud_saves import TABLES as CLOUD_TABLES
            for statement in CLOUD_TABLES:
                db.execute(statement)
            save_id = uuid.uuid4().hex
            db.execute("INSERT INTO cloud_saves(user_id,save_id,revision,record_json,content_hash,summary_json,updated_at,device_id,deleted_at) VALUES(?,?,?,?,?,?,?,?,NULL)",
                       (user_id, save_id, 1, '{"legacy":true}', "legacy-hash", '{"name":"保留云档"}', 1700000000, str(uuid.uuid4())))
            db.execute("INSERT INTO save_revisions(user_id,save_id,revision,record_json,content_hash,summary_json,updated_at,device_id) VALUES(?,?,?,?,?,?,?,?)",
                       (user_id, save_id, 1, '{"legacy":true}', "legacy-hash", '{"name":"保留云档"}', 1700000000, str(uuid.uuid4())))
        return path, user_id

    def test_schema_versions_one_through_three_migrate_idempotently_to_four(self):
        for version in (1, 2, 3):
            with self.subTest(version=version):
                path, user_id = self._legacy_db(version)
                settings = Settings(database=path, secret=os.urandom(48).hex())
                service = AuthService(settings, sender=lambda *_: "memory", clock=MutableClock())
                service = AuthService(settings, sender=lambda *_: "memory", clock=MutableClock())
                with service.connection() as db:
                    self.assertEqual(db.execute("SELECT version FROM schema_version").fetchone()[0], 4)
                    user = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
                    self.assertEqual(user["password_hash"], "retained-password-hash")
                    self.assertEqual(user["username"], "旧玩家" if version >= 2 else f"Player_{user_id.replace('-', '')[:8]}")
                    self.assertEqual(db.execute("SELECT count(*) FROM sessions WHERE user_id=?", (user_id,)).fetchone()[0], 1)
                    self.assertEqual(db.execute("SELECT count(*) FROM cloud_saves WHERE user_id=?", (user_id,)).fetchone()[0], 1)
                    self.assertEqual(db.execute("SELECT count(*) FROM save_revisions WHERE user_id=?", (user_id,)).fetchone()[0], 1)
                    self.assertTrue(db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='ranked_runs'").fetchone())

    def test_migration_ddl_failure_rolls_back_without_partial_v4_state(self):
        path, _ = self._legacy_db(3)
        settings = Settings(database=path, secret=os.urandom(48).hex())
        from unittest.mock import patch
        import app as app_module
        with patch.object(app_module, "LEADERBOARD_TABLES", (
                "CREATE TABLE transient_migration_probe(id INTEGER)",
                "CREATE TABLE leaderboard_bests (",
        )):
            with self.assertRaises(sqlite3.OperationalError):
                AuthService(settings, sender=lambda *_: "memory", clock=MutableClock())
        with closing(sqlite3.connect(path)) as connection, connection as db:
            self.assertEqual(db.execute("SELECT version FROM schema_version").fetchone()[0], 3)
            self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='transient_migration_probe'").fetchone())


if __name__ == "__main__":
    unittest.main()
