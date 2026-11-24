"""PSI HAND account service. Run one worker; all credentials stay on the server."""

from __future__ import annotations

import asyncio
import base64
from contextlib import asynccontextmanager, contextmanager
from dataclasses import dataclass
import hashlib
import hmac
import logging
import os
from pathlib import Path
import secrets
import sqlite3
import threading
import time
from typing import Literal
import unicodedata
import uuid

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from cryptography.fernet import Fernet
from email_validator import EmailNotValidError, validate_email
from fastapi import FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
import httpx
from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator

from cloud_saves import CloudError, CloudSaves, Mutation, PutSave
from request_limits import RequestLimits
from leaderboards import LeaderboardError, Leaderboards, RunResult, StartRun, StatsUpdate
from leaderboards import TABLES as LEADERBOARD_TABLES, migrate_v4_tables

LOG = logging.getLogger("psi_hand.auth")
ACCESS_SECONDS = 900
REFRESH_SECONDS = 30 * 86400
CODE_SECONDS = 300
GENERIC_CODE_MESSAGE = "If this address is eligible, a verification code will arrive shortly."


@dataclass(frozen=True)
class Settings:
    database: Path
    secret: str
    resend_key: str = ""
    sender: str = "PSI HAND <noreply@mail.game.dukechen.top>"
    mail_daily_limit: int = 90
    code_cooldown: int = 60

    def __post_init__(self):
        if len(self.secret) < 32:
            raise ValueError("AUTH_SECRET must contain at least 32 random characters")

    @classmethod
    def environment(cls):
        key_file = os.getenv("RESEND_API_KEY_FILE", "")
        key = Path(key_file).read_text(encoding="utf-8").strip() if key_file else os.getenv("RESEND_API_KEY", "")
        return cls(
            Path(os.getenv("AUTH_DATABASE", "/var/lib/psi-hand-api/accounts.sqlite3")),
            os.environ["AUTH_SECRET"], key,
            os.getenv("MAIL_FROM", "PSI HAND <noreply@mail.game.dukechen.top>"),
            int(os.getenv("MAIL_DAILY_LIMIT", "90")),
        )


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, retry_after: int = 0):
        self.status, self.code, self.message, self.retry_after = status, code, message, retry_after


class Body(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=False)


class EmailBody(Body):
    email: str = Field(min_length=3, max_length=254)

    @field_validator("email")
    @classmethod
    def email_address(cls, value):
        try:
            return validate_email(value.strip(), check_deliverability=False).normalized.lower()
        except EmailNotValidError:
            raise ValueError("Enter a valid email address") from None


class CodeRequest(EmailBody):
    purpose: Literal["register", "reset"]


class LoginRequest(EmailBody):
    password: SecretStr = Field(min_length=1, max_length=128)


class VerifyRequest(EmailBody):
    password: SecretStr = Field(min_length=8, max_length=128)
    challenge_id: str = Field(pattern=r"^[0-9a-f-]{36}$")
    code: str = Field(pattern=r"^[0-9]{6}$")


def clean_username(value: str):
    value = unicodedata.normalize("NFC", value).strip()
    if not 2 <= len(value) <= 24 or any(unicodedata.category(char)[0] not in ("L", "N") and char not in " _-" for char in value):
        raise ValueError("Display name must be 2-24 letters, numbers, spaces, underscores or hyphens")
    return value


class RegisterRequest(VerifyRequest):
    # Omission is accepted for the previous client; new clients supply a display name.
    username: str = Field(default="", max_length=48)

    @field_validator("username")
    @classmethod
    def display_name(cls, value):
        return clean_username(value)


class ProfileRequest(Body):
    username: str = Field(max_length=48)

    @field_validator("username")
    @classmethod
    def display_name(cls, value):
        return clean_username(value)


class TutorialRequest(Body):
    state: Literal["completed", "skipped"]


class RefreshRequest(Body):
    refresh_token: SecretStr = Field(min_length=40, max_length=128)


SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
INSERT INTO schema_version SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
CREATE TABLE IF NOT EXISTS users (
 id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL,
 created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS challenges (
 id TEXT PRIMARY KEY, email TEXT NOT NULL, purpose TEXT NOT NULL, code_hash TEXT NOT NULL,
 eligible INTEGER NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
 attempts INTEGER NOT NULL DEFAULT 0, consumed INTEGER NOT NULL DEFAULT 0, sent_at INTEGER
);
CREATE INDEX IF NOT EXISTS challenge_email ON challenges(email, purpose, created_at);
CREATE TABLE IF NOT EXISTS mail_outbox (
 challenge_id TEXT PRIMARY KEY REFERENCES challenges(id), payload BLOB,
 status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
 next_try INTEGER NOT NULL, provider_id TEXT
);
CREATE TABLE IF NOT EXISTS sessions (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
 access_hash TEXT UNIQUE NOT NULL, refresh_hash TEXT UNIQUE NOT NULL,
 access_expires INTEGER NOT NULL, refresh_expires INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS session_user ON sessions(user_id);
CREATE TABLE IF NOT EXISTS rate_limits (
 bucket TEXT NOT NULL, window INTEGER NOT NULL, count INTEGER NOT NULL,
 PRIMARY KEY(bucket, window)
);
"""


class AuthService:
    def __init__(self, settings: Settings, sender=None, clock=time.time):
        self.settings, self.clock = settings, clock
        self.sender = sender or self._resend
        self.mail_ready = bool(sender or settings.resend_key)
        self.passwords = PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1)
        self.dummy_password = self.passwords.hash(secrets.token_urlsafe(32))
        self.cipher = Fernet(base64.urlsafe_b64encode(hmac.digest(settings.secret.encode(), b"mail-outbox-v1", "sha256")))
        self.mail_lock = threading.Lock()
        settings.database.parent.mkdir(parents=True, exist_ok=True)
        with self.connection() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript(SCHEMA)
            version = db.execute("SELECT version FROM schema_version").fetchone()[0]
            if version not in (1, 2, 3, 4, 5):
                raise RuntimeError("Unsupported database schema")
        if version == 1:
            with self.transaction() as db:
                db.execute("ALTER TABLE users ADD COLUMN username TEXT NOT NULL DEFAULT ''")
                db.execute("UPDATE users SET username='Player_' || substr(replace(id,'-',''),1,8)")
                db.execute("UPDATE schema_version SET version=2")
        self.cloud = CloudSaves(self)
        # The leaderboard migration is atomic and keeps prior grants and responses.
        with self.transaction() as db:
            current = db.execute("SELECT version FROM schema_version").fetchone()[0]
            if current == 3:
                for statement in LEADERBOARD_TABLES:
                    db.execute(statement)
            elif current == 4:
                migrate_v4_tables(db)
            if current < 5:
                db.execute("UPDATE schema_version SET version=5")
        # This additive migration keeps the existing schema version contract.
        with self.transaction() as db:
            columns = {column["name"] for column in db.execute("PRAGMA table_info(users)")}
            if "tutorial_state" not in columns:
                db.execute("""
                    ALTER TABLE users ADD COLUMN tutorial_state TEXT NOT NULL DEFAULT 'exempt'
                    CHECK(tutorial_state IN ('pending', 'exempt', 'completed', 'skipped'))
                """)
        self.leaderboards = Leaderboards(self)

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.settings.database, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            yield db
        finally:
            db.close()

    @contextmanager
    def transaction(self):
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
                db.commit()
            except Exception:
                db.rollback()
                raise

    def now(self):
        return int(self.clock())

    def digest(self, value: str):
        return hashlib.sha256(value.encode()).hexdigest()

    def private_id(self, value: str):
        return hmac.new(self.settings.secret.encode(), value.encode(), hashlib.sha256).hexdigest()

    def code_digest(self, challenge: str, email: str, purpose: str, code: str):
        return self.private_id(f"code:{challenge}:{email}:{purpose}:{code}")

    def rate_limit(self, db, key, period, maximum):
        now = self.now()
        window = now // period
        row = db.execute("SELECT count FROM rate_limits WHERE bucket=? AND window=?", (key, window)).fetchone()
        if row and row[0] >= maximum:
            raise ApiError(429, "rate_limited", "Too many attempts. Please try again later.", period - now % period)
        db.execute("INSERT INTO rate_limits VALUES(?,?,1) ON CONFLICT(bucket,window) DO UPDATE SET count=count+1", (key, window))

    def auth_limit(self, email: str, ip: str, operation: str):
        with self.transaction() as db:
            self.rate_limit(db, f"{operation}:ip:{self.private_id(ip)}", 900, 40)
            self.rate_limit(db, f"{operation}:email:{self.private_id(email)}", 900, 15)

    def request_code(self, body: CodeRequest, ip: str):
        if not self.mail_ready:
            raise ApiError(503, "mail_unavailable", "Email verification is not available yet. You can play as a guest.")
        now, challenge, code = self.now(), str(uuid.uuid4()), f"{secrets.randbelow(1000000):06d}"
        with self.transaction() as db:
            last = db.execute("SELECT MAX(created_at) FROM challenges WHERE email=?", (body.email,)).fetchone()[0]
            if last is not None and now - last < self.settings.code_cooldown:
                raise ApiError(429, "rate_limited", "Please wait before requesting another code.", self.settings.code_cooldown - now + last)
            self.rate_limit(db, "mail:ip:" + self.private_id(ip), 3600, 30)
            self.rate_limit(db, "mail:email:" + self.private_id(body.email), 86400, 10)
            self.rate_limit(db, "mail:global", 86400, self.settings.mail_daily_limit)
            exists = db.execute("SELECT 1 FROM users WHERE email=?", (body.email,)).fetchone() is not None
            eligible = (not exists) if body.purpose == "register" else exists
            db.execute("INSERT INTO challenges(id,email,purpose,code_hash,eligible,created_at,expires_at) VALUES(?,?,?,?,?,?,?)", (challenge, body.email, body.purpose, self.code_digest(challenge, body.email, body.purpose, code), int(eligible), now, now + CODE_SECONDS))
            if eligible:
                db.execute("INSERT INTO mail_outbox(challenge_id,payload,next_try) VALUES(?,?,?)", (challenge, self.cipher.encrypt(code.encode()), now))
        return {"challenge_id": challenge, "retry_after": self.settings.code_cooldown, "message": GENERIC_CODE_MESSAGE}

    def _resend(self, email: str, purpose: str, code: str, challenge: str):
        action = "create your account" if purpose == "register" else "reset your password"
        with httpx.Client(timeout=12, follow_redirects=False) as client:
            response = client.post("https://api.resend.com/emails", headers={"Authorization": "Bearer " + self.settings.resend_key, "Idempotency-Key": "psi-hand-code/" + challenge}, json={
                "from": self.settings.sender, "to": [email], "subject": "Your PSI HAND verification code",
                "text": f"Your verification code is {code}.\n\nUse it to {action}. It expires in 5 minutes and can only be used once.\n\nIf you did not request this, ignore this message.\nPSI HAND",
            })
        # Provider responses can contain personal data: never include their body in logs.
        if response.status_code not in (200, 201):
            raise RuntimeError("mail_provider_rejected")
        return str(response.json()["id"])

    def deliver_pending(self):
        if not self.mail_lock.acquire(blocking=False):
            return
        try:
            with self.connection() as db:
                rows = db.execute("SELECT o.*,c.email,c.purpose,c.expires_at FROM mail_outbox o JOIN challenges c ON c.id=o.challenge_id WHERE o.status='pending' AND o.next_try<=? ORDER BY o.next_try LIMIT 8", (self.now(),)).fetchall()
            for row in rows:
                if row["expires_at"] <= self.now():
                    with self.transaction() as db:
                        db.execute("UPDATE mail_outbox SET status='expired',payload=NULL WHERE challenge_id=?", (row["challenge_id"],))
                    continue
                try:
                    code = self.cipher.decrypt(row["payload"]).decode()
                    provider_id = self.sender(row["email"], row["purpose"], code, row["challenge_id"])
                    with self.transaction() as db:
                        db.execute("UPDATE challenges SET consumed=1 WHERE email=? AND purpose=? AND id<>? AND created_at<=(SELECT created_at FROM challenges WHERE id=?)", (row["email"], row["purpose"], row["challenge_id"], row["challenge_id"]))
                        db.execute("UPDATE challenges SET sent_at=? WHERE id=?", (self.now(), row["challenge_id"]))
                        db.execute("UPDATE mail_outbox SET status='sent',payload=NULL,provider_id=? WHERE challenge_id=?", (provider_id, row["challenge_id"]))
                except Exception:
                    attempts = row["attempts"] + 1
                    with self.transaction() as db:
                        db.execute("UPDATE mail_outbox SET attempts=?,next_try=?,status=?,payload=CASE WHEN ? THEN NULL ELSE payload END WHERE challenge_id=?", (attempts, self.now() + min(60, 5 * 2**attempts), "failed" if attempts >= 5 else "pending", attempts >= 5, row["challenge_id"]))
                    LOG.warning("Verification delivery failed; attempt=%d", attempts)
        finally:
            self.mail_lock.release()

    def consume_code(self, db, body: VerifyRequest, purpose: str):
        row = db.execute("SELECT * FROM challenges WHERE id=? AND email=? AND purpose=?", (body.challenge_id, body.email, purpose)).fetchone()
        if not row or row["consumed"] or not row["eligible"] or row["sent_at"] is None or row["expires_at"] <= self.now() or row["attempts"] >= 5:
            return False
        if not hmac.compare_digest(row["code_hash"], self.code_digest(body.challenge_id, body.email, purpose, body.code)):
            db.execute("UPDATE challenges SET attempts=attempts+1 WHERE id=?", (body.challenge_id,))
            return False
        db.execute("UPDATE challenges SET consumed=1 WHERE id=?", (body.challenge_id,))
        return True

    def new_session(self, db, user, session_id=None, refresh_expires=None):
        now = self.now()
        access, refresh = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        refresh_expires = refresh_expires or now + REFRESH_SECONDS
        if session_id:
            db.execute("UPDATE sessions SET access_hash=?,refresh_hash=?,access_expires=? WHERE id=?", (self.digest(access), self.digest(refresh), now + ACCESS_SECONDS, session_id))
        else:
            # Bound session storage while allowing multiple devices.
            active = db.execute("SELECT id FROM sessions WHERE user_id=? ORDER BY refresh_expires DESC", (user["id"],)).fetchall()
            for old in active[9:]:
                db.execute("DELETE FROM sessions WHERE id=?", (old["id"],))
            db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?)", (str(uuid.uuid4()), user["id"], self.digest(access), self.digest(refresh), now + ACCESS_SECONDS, refresh_expires))
        profile = db.execute("SELECT id,email,username,tutorial_state FROM users WHERE id=?", (user["id"],)).fetchone()
        return {"access_token": access, "refresh_token": refresh, "expires_in": ACCESS_SECONDS, "refresh_expires_at": refresh_expires, "user": dict(profile)}

    def register(self, body: RegisterRequest, ip: str):
        self.auth_limit(body.email, ip, "verify")
        encoded = self.passwords.hash(body.password.get_secret_value())
        result = None
        with self.transaction() as db:
            if self.consume_code(db, body, "register"):
                if not db.execute("SELECT 1 FROM users WHERE email=?", (body.email,)).fetchone():
                    user = {"id": str(uuid.uuid4()), "email": body.email}
                    name = body.username or "Player_" + user["id"].replace("-", "")[:8]
                    db.execute("INSERT INTO users(id,email,password_hash,created_at,username,tutorial_state) VALUES(?,?,?,?,?,'pending')", (user["id"], user["email"], encoded, self.now(), name))
                    result = self.new_session(db, user)
        if result is None:
            raise ApiError(400, "invalid_code", "This code is invalid or expired. Please request a new code.")
        return result

    def login(self, body: LoginRequest, ip: str):
        self.auth_limit(body.email, ip, "login")
        with self.connection() as db:
            user = db.execute("SELECT * FROM users WHERE email=?", (body.email,)).fetchone()
        try:
            valid = self.passwords.verify(user["password_hash"] if user else self.dummy_password, body.password.get_secret_value())
        except VerificationError:
            valid = False
        if not user or not valid:
            raise ApiError(401, "invalid_login", "Email or password is incorrect.")
        with self.transaction() as db:
            # A reset between password verification and session creation must win.
            current = db.execute("SELECT password_hash FROM users WHERE id=?", (user["id"],)).fetchone()
            if not current or current[0] != user["password_hash"]:
                raise ApiError(401, "invalid_login", "Email or password is incorrect.")
            return self.new_session(db, user)

    def reset(self, body: VerifyRequest, ip: str):
        self.auth_limit(body.email, ip, "verify")
        encoded = self.passwords.hash(body.password.get_secret_value())
        valid = False
        with self.transaction() as db:
            if self.consume_code(db, body, "reset"):
                user = db.execute("SELECT id FROM users WHERE email=?", (body.email,)).fetchone()
                if user:
                    db.execute("UPDATE users SET password_hash=? WHERE id=?", (encoded, user[0]))
                    db.execute("DELETE FROM sessions WHERE user_id=?", (user[0],))
                    db.execute("UPDATE challenges SET consumed=1 WHERE email=?", (body.email,))
                    valid = True
        if not valid:
            raise ApiError(400, "invalid_code", "This code is invalid or expired. Please request a new code.")
        return {"message": "Password updated. Please log in again."}

    def refresh(self, body: RefreshRequest, ip: str):
        with self.transaction() as db:
            self.rate_limit(db, "refresh:ip:" + self.private_id(ip), 60, 60)
        with self.transaction() as db:
            session = db.execute("SELECT * FROM sessions WHERE refresh_hash=? AND refresh_expires>?", (self.digest(body.refresh_token.get_secret_value()), self.now())).fetchone()
            if not session:
                raise ApiError(401, "session_expired", "Your session has expired. Please log in again.")
            user = db.execute("SELECT id,email FROM users WHERE id=?", (session["user_id"],)).fetchone()
            return self.new_session(db, user, session["id"], session["refresh_expires"])

    def authenticated_user(self, db, request: Request):
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer ") or not 40 <= len(authorization[7:]) <= 128:
            raise ApiError(401, "session_expired", "Please log in again.")
        user = db.execute("SELECT u.id,u.email,u.username,u.tutorial_state FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.access_hash=? AND s.access_expires>? AND s.refresh_expires>?", (self.digest(authorization[7:]), self.now(), self.now())).fetchone()
        if not user:
            raise ApiError(401, "session_expired", "Please log in again.")
        return dict(user)

    def me(self, request: Request):
        with self.connection() as db:
            return self.authenticated_user(db, request)

    def update_profile(self, body: ProfileRequest, request: Request):
        with self.transaction() as db:
            user = self.authenticated_user(db, request)
            self.rate_limit(db, "profile:user:" + user["id"], 60, 10)
            db.execute("UPDATE users SET username=? WHERE id=?", (body.username, user["id"]))
            return {**user, "username": body.username}

    def finish_tutorial(self, body: TutorialRequest, request: Request):
        with self.transaction() as db:
            user = self.authenticated_user(db, request)
            state = user["tutorial_state"]
            if state == "pending":
                db.execute("UPDATE users SET tutorial_state=? WHERE id=?", (body.state, user["id"]))
                state = body.state
            return {"tutorial_state": state}

    def logout(self, body: RefreshRequest):
        with self.transaction() as db:
            db.execute("DELETE FROM sessions WHERE refresh_hash=?", (self.digest(body.refresh_token.get_secret_value()),))
        return {"message": "Logged out."}

    def cleanup(self):
        now = self.now()
        with self.transaction() as db:
            self.cloud.cleanup(db)
            self.leaderboards.cleanup(db)
            db.execute("DELETE FROM rate_limits WHERE window<? AND bucket LIKE 'leaderboard:ingress:%'", (now // 60 - 1,))
            db.execute("DELETE FROM mail_outbox WHERE challenge_id IN (SELECT id FROM challenges WHERE expires_at<?)", (now - 86400,))
            db.execute("DELETE FROM challenges WHERE expires_at<?", (now - 86400,))
            db.execute("DELETE FROM sessions WHERE refresh_expires<=?", (now,))
            # The largest fixed window is one day; preserve current and previous windows.
            db.execute("DELETE FROM rate_limits WHERE window < ? AND bucket LIKE 'mail:email:%'", (now // 86400 - 1,))
            db.execute("DELETE FROM rate_limits WHERE window < ? AND bucket='mail:global'", (now // 86400 - 1,))
            db.execute("DELETE FROM rate_limits WHERE window < ? AND bucket LIKE 'mail:ip:%'", (now // 3600 - 1,))
            db.execute("DELETE FROM rate_limits WHERE window < ? AND (bucket LIKE 'login:%' OR bucket LIKE 'verify:%')", (now // 900 - 1,))
            db.execute("DELETE FROM rate_limits WHERE window < ? AND bucket LIKE 'refresh:%'", (now // 60 - 1,))
            db.execute("DELETE FROM rate_limits WHERE window < ? AND bucket LIKE 'profile:%'", (now // 60 - 1,))


def create_app(settings: Settings, sender=None, clock=time.time):
    service = AuthService(settings, sender, clock)

    async def worker():
        iteration = 0
        while True:
            try:
                await asyncio.to_thread(service.deliver_pending)
                if iteration % 60 == 0:
                    await asyncio.to_thread(service.cleanup)
                iteration += 1
            except Exception:
                LOG.error("Account maintenance failed")
            await asyncio.sleep(2)

    @asynccontextmanager
    async def lifespan(_app):
        task = asyncio.create_task(worker())
        yield
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    app = FastAPI(title="PSI HAND Accounts", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.auth = service
    app.add_middleware(RequestLimits)

    @app.exception_handler(CloudError)
    async def cloud_error(_request, exc):
        return JSONResponse({"error": exc.error}, status_code=exc.status)

    @app.exception_handler(LeaderboardError)
    async def leaderboard_error(_request, exc):
        return JSONResponse({"error": exc.error}, status_code=exc.status)

    @app.exception_handler(ApiError)
    async def api_error(_request, exc):
        error = {"code": exc.code, "message": exc.message}
        headers = {}
        if exc.retry_after:
            error["retry_after"] = exc.retry_after
            headers["Retry-After"] = str(exc.retry_after)
        return JSONResponse({"error": error}, status_code=exc.status, headers=headers)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_request, exc):
        # Never echo input fields, especially passwords and verification codes.
        fields = {str(part) for item in exc.errors() for part in item.get("loc", ())}
        if _request.url.path == "/api/v1/me/stats":
            error = {"code": "invalid_stats_request", "message": "Submit a valid non-negative integer for best kills."}
        elif _leaderboard_path(_request.url.path):
            error = {"code": "invalid_leaderboard_request", "message": "Check the run, rules, version and milestone times."}
        elif _request.url.path.startswith("/api/v1/saves"):
            error = {"code": "invalid_save_request", "message": "Check the save, base revision, device ID and operation ID."}
        elif "password" in fields:
            error = {"code": "invalid_password_length", "message": "Password must be 8-128 characters."}
        elif "email" in fields:
            error = {"code": "invalid_email", "message": "Enter a valid email address."}
        elif "code" in fields or "challenge_id" in fields:
            error = {"code": "invalid_code_input", "message": "Enter a valid verification code."}
        elif "username" in fields:
            error = {"code": "invalid_username", "message": "Use a display name of 2-24 letters, numbers, spaces, underscores or hyphens."}
        else:
            error = {"code": "invalid_input", "message": "Check the submitted fields and try again."}
        return JSONResponse({"error": error}, status_code=422)

    def _leaderboard_path(path):
        return (path == "/api/v1/leaderboards" or path.startswith("/api/v1/ranked-runs")
                or path in ("/api/v1/me/leaderboard", "/api/v1/me/stats"))

    def _leaderboard_attempt(source):
        # Count attempts before JSON validation, independently of business rollback.
        with service.transaction() as db:
            service.rate_limit(db, "leaderboard:ingress:" + service.private_id(source), 60, 300)

    @app.middleware("http")
    async def boundaries(request, call_next):
        response = None
        if _leaderboard_path(request.url.path):
            try:
                await asyncio.to_thread(_leaderboard_attempt, ip(request))
            except ApiError as exc:
                response = await api_error(request, exc)
        if response is None:
            response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    def ip(request):
        return request.client.host if request.client else "unknown"

    @app.get("/api/v1/health")
    def health():
        return {"status": "ok", "service": "psi-hand-accounts", "version": 1}

    @app.post("/api/v1/auth/email-codes", status_code=202)
    def code(body: CodeRequest, request: Request):
        return service.request_code(body, ip(request))

    @app.post("/api/v1/auth/register", status_code=201)
    def register(body: RegisterRequest, request: Request):
        return service.register(body, ip(request))

    @app.post("/api/v1/auth/login")
    def login(body: LoginRequest, request: Request):
        return service.login(body, ip(request))

    @app.post("/api/v1/auth/password-reset")
    def reset(body: VerifyRequest, request: Request):
        return service.reset(body, ip(request))

    @app.post("/api/v1/auth/refresh")
    def refresh(body: RefreshRequest, request: Request):
        return service.refresh(body, ip(request))

    @app.post("/api/v1/auth/logout")
    def logout(body: RefreshRequest):
        return service.logout(body)

    @app.get("/api/v1/me")
    def me(request: Request):
        return service.me(request)

    @app.patch("/api/v1/me")
    def update_profile(body: ProfileRequest, request: Request):
        return service.update_profile(body, request)

    @app.post("/api/v1/me/tutorial")
    def finish_tutorial(body: TutorialRequest, request: Request):
        return service.finish_tutorial(body, request)

    @app.post("/api/v1/ranked-runs", status_code=201)
    def start_ranked_run(body: StartRun, request: Request):
        return service.leaderboards.start(request, body)

    @app.put("/api/v1/ranked-runs/{run_id}/result")
    def finish_ranked_run(run_id: str, body: RunResult, request: Request):
        return service.leaderboards.finish(request, run_id, body)

    @app.get("/api/v1/leaderboards")
    def list_leaderboard(request: Request, ruleset_id: str = Query(default="survival_v1", max_length=64),
                         cursor: str = Query(default="", max_length=512)):
        return service.leaderboards.list_board(request, ruleset_id, cursor)

    @app.get("/api/v1/me/leaderboard")
    def personal_leaderboard(request: Request, ruleset_id: str = Query(default="survival_v1", max_length=64)):
        return service.leaderboards.personal(request, ruleset_id)

    @app.get("/api/v1/me/stats")
    def get_player_stats(request: Request):
        return service.leaderboards.get_stats(request)

    @app.put("/api/v1/me/stats")
    def update_player_stats(body: StatsUpdate, request: Request):
        return service.leaderboards.put_stats(request, body)

    @app.get("/api/v1/saves")
    def list_saves(request: Request, after: str = ""):
        return service.cloud.list(request, after)

    @app.get("/api/v1/saves/{save_id}")
    def get_save(save_id: str, request: Request):
        return service.cloud.get(request, save_id)

    @app.put("/api/v1/saves/{save_id}")
    def put_save(save_id: str, body: PutSave, request: Request):
        return service.cloud.put(request, save_id, body)

    @app.delete("/api/v1/saves/{save_id}")
    def delete_save(save_id: str, body: Mutation, request: Request):
        return service.cloud.delete(request, save_id, body)

    @app.get("/api/v1/saves/{save_id}/revisions")
    def list_revisions(save_id: str, request: Request):
        return service.cloud.history(request, save_id)

    @app.get("/api/v1/saves/{save_id}/revisions/{revision}")
    def get_revision(save_id: str, revision: int, request: Request):
        return service.cloud.history(request, save_id, revision)

    return app


def from_environment():
    return create_app(Settings.environment())
