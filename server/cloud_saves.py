"""Account-scoped, conditional cloud storage. Never executes a save payload."""
from __future__ import annotations

import hashlib
import json
import re
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from save_payload import InvalidSave, canonical_save

MAX_ACTIVE_SAVES = 10
HISTORY_COUNT = 3
RETENTION_SECONDS = 30 * 86400
SAVE_ID = re.compile(r"^[0-9a-f]{32}$")


class Mutation(BaseModel):
    model_config = ConfigDict(extra="forbid")
    base_revision: int = Field(ge=0, le=2**53 - 2, strict=True)
    operation_id: UUID
    device_id: UUID


class PutSave(Mutation):
    record: dict


class CloudError(Exception):
    def __init__(self, status, code, message, current=None):
        self.status = status
        self.error = {"code": code, "message": message}
        if code in ("revision_conflict", "save_deleted"):
            self.error["current"] = current


TABLES = (
    """CREATE TABLE IF NOT EXISTS cloud_saves (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    save_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
    record_json TEXT, content_hash TEXT, summary_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL, device_id TEXT NOT NULL, deleted_at INTEGER,
    PRIMARY KEY(user_id,save_id))""",
    """CREATE TABLE IF NOT EXISTS save_revisions (
    user_id TEXT NOT NULL, save_id TEXT NOT NULL, revision INTEGER NOT NULL,
    record_json TEXT NOT NULL, content_hash TEXT NOT NULL, summary_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL, device_id TEXT NOT NULL,
    PRIMARY KEY(user_id,save_id,revision),
    FOREIGN KEY(user_id,save_id) REFERENCES cloud_saves(user_id,save_id) ON DELETE CASCADE)""",
    """CREATE TABLE IF NOT EXISTS save_operations (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation_id TEXT NOT NULL, fingerprint TEXT NOT NULL, response_json TEXT NOT NULL,
    created_at INTEGER NOT NULL, PRIMARY KEY(user_id,operation_id))""",
    "CREATE INDEX IF NOT EXISTS save_operations_age ON save_operations(created_at)",
)


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


class CloudSaves:
    def __init__(self, auth):
        self.auth = auth
        # execute each statement: executescript would implicitly commit the migration.
        with auth.transaction() as db:
            for statement in TABLES:
                db.execute(statement)
            db.execute("UPDATE schema_version SET version=3 WHERE version<3")

    def _id(self, save_id):
        if not SAVE_ID.fullmatch(save_id):
            raise CloudError(422, "invalid_save_id", "Choose a valid save.")

    def _user(self, db, request, writing=False):
        user_id = self.auth.authenticated_user(db, request)["id"]
        self.auth.rate_limit(db, "cloud:minute:" + user_id, 60, 120)
        if writing:
            self.auth.rate_limit(db, "cloud:write:" + user_id, 60, 60)
            self.auth.rate_limit(db, "cloud:day:" + user_id, 86400, 1000)
        return user_id

    @staticmethod
    def _metadata(row):
        return {
            "save_id": row["save_id"], "revision": row["revision"],
            "deleted": row["deleted_at"] is not None,
            "content_hash": row["content_hash"], "updated_at": row["updated_at"],
            "device_id": row["device_id"], "summary": json.loads(row["summary_json"]),
        }

    def list(self, request, after=""):
        if after:
            self._id(after)
        with self.auth.transaction() as db:
            user_id = self._user(db, request)
            rows = db.execute("SELECT * FROM cloud_saves WHERE user_id=? AND save_id>? ORDER BY save_id LIMIT 101", (user_id, after)).fetchall()
            return {"protocol_version": 1, "saves": [self._metadata(row) for row in rows[:100]],
                    "next_cursor": rows[99]["save_id"] if len(rows) > 100 else None, "server_time": self.auth.now()}

    def get(self, request, save_id):
        self._id(save_id)
        with self.auth.transaction() as db:
            user_id = self._user(db, request)
            row = db.execute("SELECT * FROM cloud_saves WHERE user_id=? AND save_id=?", (user_id, save_id)).fetchone()
            if row is None:
                raise CloudError(404, "save_not_found", "This cloud save does not exist.")
            return {**self._metadata(row), "record_json": row["record_json"]}

    def history(self, request, save_id, revision=None):
        self._id(save_id)
        with self.auth.transaction() as db:
            user_id = self._user(db, request)
            current = db.execute("SELECT * FROM cloud_saves WHERE user_id=? AND save_id=?", (user_id, save_id)).fetchone()
            if current is None:
                raise CloudError(404, "save_not_found", "This cloud save does not exist.")
            rows = []
            # Even before background cleanup runs, expired deleted payloads are unreadable.
            if current["deleted_at"] is None or current["deleted_at"] > self.auth.now() - RETENTION_SECONDS:
                rows = db.execute("SELECT * FROM save_revisions WHERE user_id=? AND save_id=? ORDER BY revision DESC", (user_id, save_id)).fetchall()
            if revision is None:
                return {"save_id": save_id, "revisions": [self._metadata({**dict(row), "deleted_at": None}) for row in rows]}
            for row in rows:
                if row["revision"] == revision:
                    return {**self._metadata({**dict(row), "deleted_at": None}), "record_json": row["record_json"]}
            raise CloudError(404, "revision_not_found", "This cloud revision is no longer available.")

    def put(self, request, save_id, body: PutSave):
        self._id(save_id)
        try:
            record_json, content_hash = canonical_save(body.record, save_id)
        except InvalidSave:
            raise CloudError(422, "invalid_save", "This save is damaged or uses an unsupported format.") from None
        return self._mutate(request, save_id, body, record_json, content_hash)

    def delete(self, request, save_id, body: Mutation):
        self._id(save_id)
        return self._mutate(request, save_id, body)

    def _mutate(self, request, save_id, body, record_json=None, content_hash=None):
        verb = "DELETE" if record_json is None else "PUT"
        fingerprint = hashlib.sha256(encoded({
            "method": verb, "save_id": save_id, "base_revision": body.base_revision,
            "device_id": str(body.device_id), "record_json": record_json,
        }).encode("utf-8")).hexdigest()
        now = self.auth.now()
        with self.auth.transaction() as db:
            user_id = self._user(db, request, writing=True)
            operation = db.execute("SELECT * FROM save_operations WHERE user_id=? AND operation_id=?", (user_id, str(body.operation_id))).fetchone()
            if operation and operation["created_at"] >= now - RETENTION_SECONDS:
                if operation["fingerprint"] != fingerprint:
                    raise CloudError(409, "operation_mismatch", "Use a new operation ID for a different change.")
                return json.loads(operation["response_json"])
            if operation:
                db.execute("DELETE FROM save_operations WHERE user_id=? AND operation_id=?", (user_id, str(body.operation_id)))
            current = db.execute("SELECT * FROM cloud_saves WHERE user_id=? AND save_id=?", (user_id, save_id)).fetchone()
            if body.base_revision != (current["revision"] if current else 0):
                raise CloudError(409, "revision_conflict", "This save changed on another device. Choose which copy to keep.", self._metadata(current) if current else None)
            if current is not None and current["deleted_at"] is not None:
                raise CloudError(409, "save_deleted", "This save was deleted. Keep an offline copy under a new save ID.", self._metadata(current))
            if current is None and verb == "DELETE":
                raise CloudError(404, "save_not_found", "This cloud save does not exist.")
            if current is None:
                count = db.execute("SELECT count(*) FROM cloud_saves WHERE user_id=? AND deleted_at IS NULL", (user_id,)).fetchone()[0]
                if count >= MAX_ACTIVE_SAVES:
                    raise CloudError(409, "save_quota", "You can keep up to 10 active cloud saves. Delete one before uploading another.")
            if current is not None:
                db.execute("""INSERT INTO save_revisions(user_id,save_id,revision,record_json,content_hash,summary_json,updated_at,device_id)
                VALUES(?,?,?,?,?,?,?,?)""", (user_id, save_id, current["revision"], current["record_json"], current["content_hash"], current["summary_json"], current["updated_at"], current["device_id"]))
            if record_json is not None:
                record = json.loads(record_json)
                checkpoint = record["checkpoint"]
                summary = {key: record[key] for key in ("name", "created_at", "saved_at", "saved_unix")}
                summary["save_kind"] = record.get("save_kind", "manual")
                summary["checkpoint"] = checkpoint
                summary_json = encoded(summary)
            else:
                summary = json.loads(current["summary_json"])
                summary["checkpoint"] = {key: summary["checkpoint"][key] for key in ("stage", "stage_name", "kind", "wave")}
                summary_json = encoded(summary)
            revision = body.base_revision + 1
            db.execute("""INSERT INTO cloud_saves(user_id,save_id,revision,record_json,content_hash,summary_json,updated_at,device_id,deleted_at)
            VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(user_id,save_id) DO UPDATE SET
            revision=excluded.revision,record_json=excluded.record_json,content_hash=excluded.content_hash,
            summary_json=excluded.summary_json,updated_at=excluded.updated_at,device_id=excluded.device_id,deleted_at=excluded.deleted_at""",
                       (user_id, save_id, revision, record_json, content_hash, summary_json, now, str(body.device_id), now if verb == "DELETE" else None))
            db.execute("DELETE FROM save_revisions WHERE user_id=? AND save_id=? AND revision NOT IN (SELECT revision FROM save_revisions WHERE user_id=? AND save_id=? ORDER BY revision DESC LIMIT ?)", (user_id, save_id, user_id, save_id, HISTORY_COUNT))
            updated = db.execute("SELECT * FROM cloud_saves WHERE user_id=? AND save_id=?", (user_id, save_id)).fetchone()
            response = self._metadata(updated)
            db.execute("INSERT INTO save_operations VALUES(?,?,?,?,?)", (user_id, str(body.operation_id), fingerprint, encoded(response), now))
            return response

    def cleanup(self, db):
        cutoff = self.auth.now() - RETENTION_SECONDS
        db.execute("DELETE FROM save_operations WHERE created_at<?", (cutoff,))
        db.execute("DELETE FROM save_revisions WHERE (user_id,save_id) IN (SELECT user_id,save_id FROM cloud_saves WHERE deleted_at IS NOT NULL AND deleted_at<=?)", (cutoff,))
        db.execute("DELETE FROM rate_limits WHERE window<? AND (bucket LIKE 'cloud:minute:%' OR bucket LIKE 'cloud:write:%')", (self.auth.now() // 60 - 1,))
        db.execute("DELETE FROM rate_limits WHERE window<? AND bucket LIKE 'cloud:day:%'", (self.auth.now() // 86400 - 1,))
