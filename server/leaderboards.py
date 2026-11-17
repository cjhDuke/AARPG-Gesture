"""Transactional leaderboard business logic for the account service."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


RULESET = "survival_v1"
VERSION = re.compile(r"^[A-Za-z0-9._+-]{1,32}$", re.ASCII)
UUID_TEXT = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
PAGE_SIZE = 20
RUN_SECONDS = 86400


class LeaderboardError(Exception):
    def __init__(self, status, code, message):
        self.status = status
        self.error = {"code": code, "message": message}
        super().__init__(message)


class _Body(BaseModel):
    model_config = ConfigDict(extra="forbid")


class StartRun(_Body):
    operation_id: UUID
    ruleset_id: str = RULESET
    client_version: str
    continued: bool = False
    practice: bool = False
    debug_used: bool = False

    @field_validator("ruleset_id")
    @classmethod
    def ruleset(cls, value):
        if value != RULESET:
            raise ValueError("Unsupported ruleset")
        return value

    @field_validator("client_version")
    @classmethod
    def version(cls, value):
        if not VERSION.fullmatch(value):
            raise ValueError("Invalid client version")
        return value

    @field_validator("continued", "practice", "debug_used", mode="before")
    @classmethod
    def strict_flag(cls, value):
        if type(value) is not bool:
            raise ValueError("Must be a boolean")
        if value:
            raise ValueError("This run is not eligible")
        return value


class RunResult(_Body):
    ruleset_id: str = RULESET
    client_version: str
    victory: bool
    kills: int = Field(ge=0, le=2147483647, strict=True)
    elapsed_ms: int = Field(ge=0, le=86400000, strict=True)
    milestone_ms: list[int] = Field(max_length=9)
    continued: bool = False
    practice: bool = False
    debug_used: bool = False

    @field_validator("ruleset_id")
    @classmethod
    def ruleset(cls, value):
        if value != RULESET:
            raise ValueError("Unsupported ruleset")
        return value

    @field_validator("client_version")
    @classmethod
    def version(cls, value):
        if not VERSION.fullmatch(value):
            raise ValueError("Invalid client version")
        return value

    @field_validator("victory", "continued", "practice", "debug_used", mode="before")
    @classmethod
    def strict_flag(cls, value):
        if type(value) is not bool:
            raise ValueError("Must be a boolean")
        return value

    @field_validator("milestone_ms", mode="before")
    @classmethod
    def strict_list(cls, value):
        if not isinstance(value, list) or any(type(item) is not int for item in value):
            raise ValueError("Milestones must be integer milliseconds")
        return value

    @model_validator(mode="after")
    def validate_result(self):
        if self.continued or self.practice or self.debug_used:
            raise ValueError("This run is not eligible")
        if any(not 1 <= item <= 86400000 for item in self.milestone_ms):
            raise ValueError("Invalid milestone time")
        if any(a > b for a, b in zip(self.milestone_ms, self.milestone_ms[1:])):
            raise ValueError("Milestones must be nondecreasing")
        if any(item > self.elapsed_ms for item in self.milestone_ms):
            raise ValueError("Milestone exceeds elapsed time")
        if self.victory:
            if len(self.milestone_ms) != 9 or self.elapsed_ms != self.milestone_ms[-1]:
                raise ValueError("Victory requires all nine milestones")
        elif len(self.milestone_ms) > 8:
            raise ValueError("A failed run cannot complete all milestones")
        return self


class StatsUpdate(_Body):
    best_kills: int = Field(ge=0, le=2147483647, strict=True)


TABLES = (
    """CREATE TABLE IF NOT EXISTS player_stats (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    best_kills INTEGER NOT NULL CHECK(best_kills BETWEEN 0 AND 2147483647), updated_at INTEGER NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS ranked_runs (
    run_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id TEXT NOT NULL, fingerprint TEXT NOT NULL, ruleset_id TEXT NOT NULL,
    client_version TEXT NOT NULL, issued_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
    start_response_json TEXT NOT NULL, result_fingerprint TEXT, response_json TEXT,
    progress INTEGER CHECK(progress BETWEEN 0 AND 9), rank_time_ms INTEGER,
    elapsed_ms INTEGER, kills INTEGER, victory INTEGER CHECK(victory IN (0,1)),
    achieved_at INTEGER, UNIQUE(user_id,operation_id),
    CHECK((result_fingerprint IS NULL AND response_json IS NULL) OR
          (result_fingerprint IS NOT NULL AND response_json IS NOT NULL)))""",
    """CREATE TABLE IF NOT EXISTS leaderboard_bests (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ruleset_id TEXT NOT NULL, entry_id TEXT NOT NULL UNIQUE,
    progress INTEGER NOT NULL CHECK(progress BETWEEN 1 AND 9),
    rank_time_ms INTEGER NOT NULL CHECK(rank_time_ms BETWEEN 1 AND 86400000),
    elapsed_ms INTEGER NOT NULL CHECK(elapsed_ms BETWEEN 0 AND 86400000),
    kills INTEGER NOT NULL CHECK(kills BETWEEN 0 AND 2147483647),
    victory INTEGER NOT NULL CHECK(victory IN (0,1)), achieved_at INTEGER NOT NULL,
    PRIMARY KEY(user_id,ruleset_id))""",
    "CREATE INDEX IF NOT EXISTS leaderboard_order ON leaderboard_bests(ruleset_id,progress DESC,rank_time_ms ASC,achieved_at ASC,entry_id ASC)",
)


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


class Leaderboards:
    def __init__(self, auth):
        self.auth = auth

    @staticmethod
    def _uuid(value, code="invalid_id"):
        if not isinstance(value, str) or not UUID_TEXT.fullmatch(value):
            raise LeaderboardError(422, code, "Choose a valid identifier.")
        try:
            if str(UUID(value)) != value:
                raise ValueError
        except ValueError:
            raise LeaderboardError(422, code, "Choose a valid identifier.") from None
        return value

    @staticmethod
    def _ruleset(value):
        if value != RULESET:
            raise LeaderboardError(422, "invalid_ruleset", "Choose a supported ruleset.")

    def _charge(self, request, writing=False, starting=False, public=False, authenticated=False):
        """Commit request counters separately so rejected business actions still count."""
        with self.auth.transaction() as db:
            if public:
                source = request.client.host if getattr(request, "client", None) else "unknown"
                self.auth.rate_limit(db, "leaderboard:public:" + self.auth.private_id(source), 60, 120)
                if not authenticated:
                    return None
            user_id = self.auth.authenticated_user(db, request)["id"]
            self.auth.rate_limit(db, "leaderboard:user:" + user_id, 60, 120)
            if writing:
                self.auth.rate_limit(db, "leaderboard:write:" + user_id, 60, 60)
                self.auth.rate_limit(db, "leaderboard:day:" + user_id, 86400, 1000)
            if starting:
                self.auth.rate_limit(db, "leaderboard:start-minute:" + user_id, 60, 6)
                self.auth.rate_limit(db, "leaderboard:start-day:" + user_id, 86400, 120)
            return user_id

    def _current_user(self, db, request):
        return self.auth.authenticated_user(db, request)["id"]

    @staticmethod
    def _fingerprint(value):
        return hashlib.sha256(encoded(value).encode("utf-8")).hexdigest()

    def start(self, request, body: StartRun):
        user_id = self._charge(request, writing=True, starting=True)
        payload = body.model_dump(mode="json")
        fingerprint = self._fingerprint(payload)
        with self.auth.transaction() as db:
            user_id = self._current_user(db, request)
            existing = db.execute("SELECT * FROM ranked_runs WHERE user_id=? AND operation_id=?", (user_id, str(body.operation_id))).fetchone()
            if existing:
                if not hmac.compare_digest(existing["fingerprint"], fingerprint):
                    raise LeaderboardError(409, "operation_mismatch", "Use a new operation ID for different run settings.")
                return json.loads(existing["start_response_json"])
            issued = self.auth.now()
            run_id = str(uuid4())
            response = {"run_id": run_id, "ruleset_id": body.ruleset_id, "client_version": body.client_version,
                        "issued_at": issued, "expires_at": issued + RUN_SECONDS, "server_time": issued}
            db.execute("INSERT INTO ranked_runs(run_id,user_id,operation_id,fingerprint,ruleset_id,client_version,issued_at,expires_at,start_response_json) VALUES(?,?,?,?,?,?,?,?,?)",
                       (run_id, user_id, str(body.operation_id), fingerprint, body.ruleset_id, body.client_version, issued, issued + RUN_SECONDS, encoded(response)))
            return response

    def finish(self, request, run_id: str, body: RunResult):
        run_id = self._uuid(run_id, "invalid_run_id")
        self._charge(request, writing=True)
        payload = body.model_dump(mode="json")
        fingerprint = self._fingerprint(payload)
        with self.auth.transaction() as db:
            user_id = self._current_user(db, request)
            run = db.execute("SELECT * FROM ranked_runs WHERE run_id=? AND user_id=?", (run_id, user_id)).fetchone()
            if run is None:
                raise LeaderboardError(404, "run_not_found", "This run does not exist.")
            if run["result_fingerprint"] is not None:
                if not hmac.compare_digest(run["result_fingerprint"], fingerprint):
                    raise LeaderboardError(409, "result_mismatch", "This run was already submitted with a different result.")
                return json.loads(run["response_json"])
            now = self.auth.now()
            if now >= run["expires_at"]:
                raise LeaderboardError(410, "run_expired", "This run has expired.")
            if body.ruleset_id != run["ruleset_id"] or body.client_version != run["client_version"]:
                raise LeaderboardError(409, "run_mismatch", "Result settings must match the run that was started.")
            if now < run["issued_at"]:
                raise LeaderboardError(422, "invalid_elapsed", "Server time moved backwards during this run.")
            if body.elapsed_ms > (now - run["issued_at"]) * 1000 + 1000:
                raise LeaderboardError(422, "invalid_elapsed", "Elapsed time exceeds the observed run duration.")
            progress = len(body.milestone_ms)
            rank_time = body.milestone_ms[-1] if progress else 0
            db.execute("UPDATE ranked_runs SET progress=?,rank_time_ms=?,elapsed_ms=?,kills=?,victory=?,achieved_at=? WHERE run_id=?",
                       (progress, rank_time, body.elapsed_ms, body.kills, int(body.victory), now, run_id))
            db.execute("INSERT INTO player_stats(user_id,best_kills,updated_at) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET best_kills=MAX(player_stats.best_kills,excluded.best_kills),updated_at=CASE WHEN excluded.best_kills>player_stats.best_kills THEN excluded.updated_at ELSE player_stats.updated_at END",
                       (user_id, body.kills, now))
            current = db.execute("SELECT * FROM leaderboard_bests WHERE user_id=? AND ruleset_id=?", (user_id, body.ruleset_id)).fetchone()
            improved = progress > 0 and (current is None or progress > current["progress"] or
                                         (progress == current["progress"] and rank_time < current["rank_time_ms"]))
            if improved:
                entry_id = current["entry_id"] if current else str(uuid4())
                db.execute("INSERT INTO leaderboard_bests(user_id,ruleset_id,entry_id,progress,rank_time_ms,elapsed_ms,kills,victory,achieved_at) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(user_id,ruleset_id) DO UPDATE SET progress=excluded.progress,rank_time_ms=excluded.rank_time_ms,elapsed_ms=excluded.elapsed_ms,kills=excluded.kills,victory=excluded.victory,achieved_at=excluded.achieved_at",
                           (user_id, body.ruleset_id, entry_id, progress, rank_time, body.elapsed_ms, body.kills, int(body.victory), now))
            best = self._public_for_user(db, user_id, body.ruleset_id)
            response = {"run_id": run_id, "ruleset_id": body.ruleset_id, "accepted": True,
                        "progress": progress, "rank_time_ms": rank_time, "improved": improved,
                        "best": best, "server_time": now}
            db.execute("UPDATE ranked_runs SET result_fingerprint=?,response_json=? WHERE run_id=?", (fingerprint, encoded(response), run_id))
            return response

    @staticmethod
    def _public_columns():
        return "b.entry_id,u.username AS player_name,b.progress,b.rank_time_ms,b.elapsed_ms,b.kills,b.victory,b.achieved_at"

    def _public_for_user(self, db, user_id, ruleset):
        row = db.execute("WITH ranked AS (SELECT b.user_id," + self._public_columns() + ",RANK() OVER(ORDER BY b.progress DESC,b.rank_time_ms ASC) AS rank FROM leaderboard_bests b JOIN users u ON u.id=b.user_id WHERE b.ruleset_id=? AND b.progress>0) SELECT * FROM ranked WHERE user_id=?", (ruleset,user_id)).fetchone()
        if row is None:
            return None
        return self._entry(row, row["rank"])

    @staticmethod
    def _entry(row, rank):
        return {"entry_id": row["entry_id"], "rank": rank, "player_name": row["player_name"],
                "progress": row["progress"], "rank_time_ms": row["rank_time_ms"], "elapsed_ms": row["elapsed_ms"],
                "kills": row["kills"], "victory": bool(row["victory"]), "achieved_at": row["achieved_at"]}

    def _cursor_key(self, ruleset):
        return self.auth.private_id("leaderboard-cursor-v1:" + ruleset).encode("ascii")

    def _encode_cursor(self, ruleset, row):
        payload = encoded([ruleset, row["progress"], row["rank_time_ms"], row["achieved_at"], row["entry_id"]]).encode("utf-8")
        sig = hmac.new(self._cursor_key(ruleset), payload, hashlib.sha256).digest()
        return base64.urlsafe_b64encode(payload + sig).decode("ascii").rstrip("=")

    def _decode_cursor(self, cursor, ruleset):
        if not cursor:
            return None
        if not isinstance(cursor, str) or len(cursor) > 512 or not re.fullmatch(r"[A-Za-z0-9_-]+", cursor):
            raise LeaderboardError(422, "invalid_cursor", "Choose a valid leaderboard cursor.")
        try:
            raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
            if base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != cursor:
                raise ValueError
            payload, signature = raw[:-32], raw[-32:]
            expected = hmac.new(self._cursor_key(ruleset), payload, hashlib.sha256).digest()
            data = json.loads(payload)
            if not hmac.compare_digest(signature, expected) or not isinstance(data, list) or len(data) != 5:
                raise ValueError
            rule, progress, rank_time, achieved, entry_id = data
            self._uuid(entry_id, "invalid_cursor")
            if rule != ruleset or any(type(x) is not int for x in (progress, rank_time, achieved)) or not 1 <= progress <= 9 or not 1 <= rank_time <= 86400000:
                raise ValueError
            return progress, rank_time, achieved, entry_id
        except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
            raise LeaderboardError(422, "invalid_cursor", "Choose a valid leaderboard cursor.") from None

    def list_board(self, request, ruleset_id=RULESET, cursor=""):
        self._ruleset(ruleset_id)
        self._charge(request, public=True)
        key = self._decode_cursor(cursor, ruleset_id)
        with self.auth.transaction() as db:
            now = self.auth.now()
            params = [ruleset_id]
            where = "1=1"
            if key:
                p, t, a, eid = key
                where += " AND (progress<? OR (progress=? AND rank_time_ms>?) OR (progress=? AND rank_time_ms=? AND achieved_at>?) OR (progress=? AND rank_time_ms=? AND achieved_at=? AND entry_id>?))"
                params += [p,p,t,p,t,a,p,t,a,eid]
            rows = db.execute("WITH ranked AS (SELECT " + self._public_columns() + ",RANK() OVER(ORDER BY b.progress DESC,b.rank_time_ms ASC) AS rank FROM leaderboard_bests b JOIN users u ON u.id=b.user_id WHERE b.ruleset_id=? AND b.progress>0) SELECT * FROM ranked WHERE " + where + " ORDER BY progress DESC,rank_time_ms ASC,achieved_at ASC,entry_id ASC LIMIT ?", (*params, PAGE_SIZE + 1)).fetchall()
            entries = [self._entry(row, row["rank"]) for row in rows[:PAGE_SIZE]]
            next_cursor = self._encode_cursor(ruleset_id, rows[PAGE_SIZE - 1]) if len(rows) > PAGE_SIZE else None
            return {"ruleset_id": ruleset_id, "rules": {"milestone_count": 9, "input_policy": "gesture_keyboard_mixed", "accepting_runs": True},
                    "entries": entries, "next_cursor": next_cursor, "generated_at": now}

    def personal(self, request, ruleset_id=RULESET):
        self._ruleset(ruleset_id)
        self._charge(request)
        with self.auth.transaction() as db:
            user_id = self._current_user(db, request)
            rows = db.execute("WITH ranked AS (SELECT b.user_id," + self._public_columns() + ",RANK() OVER(ORDER BY b.progress DESC,b.rank_time_ms ASC) AS rank,ROW_NUMBER() OVER(ORDER BY b.progress DESC,b.rank_time_ms ASC,b.achieved_at ASC,b.entry_id ASC) AS row_number FROM leaderboard_bests b JOIN users u ON u.id=b.user_id WHERE b.ruleset_id=? AND b.progress>0), own AS (SELECT row_number FROM ranked WHERE user_id=?) SELECT * FROM ranked WHERE row_number BETWEEN (SELECT row_number-2 FROM own) AND (SELECT row_number+2 FROM own) ORDER BY row_number", (ruleset_id,user_id)).fetchall()
            own = next((row for row in rows if row["user_id"] == user_id), None)
            if own is None:
                return {"ruleset_id": ruleset_id, "best": None, "neighbors": [], "generated_at": self.auth.now()}
            return {"ruleset_id": ruleset_id, "best": self._entry(own, own["rank"]),
                    "neighbors": [self._entry(row, row["rank"]) for row in rows],
                    "generated_at": self.auth.now()}

    def get_stats(self, request):
        self._charge(request)
        with self.auth.transaction() as db:
            user_id = self._current_user(db, request)
            row = db.execute("SELECT best_kills,updated_at FROM player_stats WHERE user_id=?", (user_id,)).fetchone()
            now = self.auth.now()
            return {"best_kills": row["best_kills"] if row else 0, "updated_at": row["updated_at"] if row else 0, "server_time": now}

    def put_stats(self, request, body: StatsUpdate):
        self._charge(request, writing=True)
        with self.auth.transaction() as db:
            user_id = self._current_user(db, request)
            now = self.auth.now()
            db.execute("INSERT INTO player_stats(user_id,best_kills,updated_at) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET best_kills=MAX(player_stats.best_kills,excluded.best_kills),updated_at=CASE WHEN excluded.best_kills>player_stats.best_kills THEN excluded.updated_at ELSE player_stats.updated_at END", (user_id,body.best_kills,now))
            row = db.execute("SELECT best_kills,updated_at FROM player_stats WHERE user_id=?", (user_id,)).fetchone()
            return {"best_kills": row["best_kills"], "updated_at": row["updated_at"], "server_time": now}

    def cleanup(self, db):
        """Remove only expired leaderboard limit windows; run inside AuthService.cleanup."""
        now = self.auth.now()
        db.execute("DELETE FROM rate_limits WHERE bucket GLOB 'leaderboard:user:*' AND window<?", (now // 60,))
        db.execute("DELETE FROM rate_limits WHERE bucket GLOB 'leaderboard:write:*' AND window<?", (now // 60,))
        db.execute("DELETE FROM rate_limits WHERE bucket GLOB 'leaderboard:start-minute:*' AND window<?", (now // 60,))
        db.execute("DELETE FROM rate_limits WHERE bucket GLOB 'leaderboard:day:*' AND window<?", (now // 86400,))
        db.execute("DELETE FROM rate_limits WHERE bucket GLOB 'leaderboard:start-day:*' AND window<?", (now // 86400,))
        db.execute("DELETE FROM rate_limits WHERE bucket GLOB 'leaderboard:public:*' AND window<?", (now // 60,))
