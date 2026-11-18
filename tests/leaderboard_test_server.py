"""Local-only Godot integration fixture; never deploy this file."""
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import secrets
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
from fastapi import Request
from fastapi.responses import JSONResponse
import uvicorn
from app import Settings, create_app


class Faults:
    def __init__(self):
        self.flags = set()
        self.counts = {}


class FaultMiddleware:
    def __init__(self, app, faults):
        self.app, self.faults = app, faults

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope["path"]
        label = "/api/v1/ranked-runs/:id/result" if path.endswith("/result") else path
        self.faults.counts[label] = self.faults.counts.get(label, 0) + 1
        if path == "/api/v1/me/stats" and "expire_access_once" in self.faults.flags:
            self.faults.flags.remove("expire_access_once")
            response = JSONResponse({"error": {"code": "session_expired", "message": "Test expiry"}}, status_code=401)
            return await response(scope, receive, send)
        captured = []

        async def capture(message):
            captured.append(message)

        await self.app(scope, receive, capture)
        status = next((m["status"] for m in captured if m["type"] == "http.response.start"), 500)
        if path.endswith("/result") and status == 200 and "drop_result_once" in self.faults.flags:
            self.faults.flags.remove("drop_result_once")
            response = JSONResponse({"error": {"code": "test_lost_response", "message": "Retry"}}, status_code=503)
            return await response(scope, receive, send)
        delayed = "delay_grant_once" if path == "/api/v1/ranked-runs" else "delay_personal_once" if path == "/api/v1/me/leaderboard" else ""
        if delayed and delayed in self.faults.flags:
            self.faults.flags.remove(delayed)
            await asyncio.sleep(1.8)
        for message in captured:
            await send(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--port", type=int, default=19125)
    args = parser.parse_args()
    config_path = Path(args.config).resolve()
    if not config_path.is_relative_to(ROOT / ".stage3_checks"):
        raise SystemExit("Fixture config must stay under .stage3_checks")
    config_path.parent.mkdir(parents=True, exist_ok=True)
    db_path = config_path.parent / "integration.sqlite3"
    if db_path.exists():
        raise SystemExit("Use a fresh fixture directory to avoid reusing test data")
    app = create_app(Settings(database=db_path, secret=secrets.token_urlsafe(48)), sender=lambda *_: "memory-only")
    auth = app.state.auth
    config = {"api": f"http://127.0.0.1:{args.port}/api/v1", "control_key": secrets.token_urlsafe(32), "users": {}}
    with auth.transaction() as db:
        for key in ("a", "b"):
            account = {"id": str(uuid.uuid4()), "email": f"integration-{uuid.uuid4().hex}@example.com", "password": secrets.token_urlsafe(18)}
            db.execute("INSERT INTO users(id,email,password_hash,created_at,username) VALUES(?,?,?,?,?)",
                       (account["id"], account["email"], auth.passwords.hash(account["password"]), auth.now(), "联调玩家"))
            config["users"][key] = account
    config_path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
    faults = Faults()
    app.add_middleware(FaultMiddleware, faults=faults)

    @app.post("/_test/control")
    async def control(request: Request):
        data = await request.json()
        if data.get("key") != config["control_key"]:
            return JSONResponse({"error": "test authorization required"}, status_code=403)
        action = data.get("action")
        if action not in ("drop_result_once", "delay_grant_once", "expire_access_once", "delay_personal_once"):
            return JSONResponse({"error": "unknown test action"}, status_code=422)
        faults.flags.add(action)
        return {"ok": True}

    @app.get("/_test/summary")
    def summary(key: str = ""):
        if key != config["control_key"]:
            return JSONResponse({"error": "test authorization required"}, status_code=403)
        with auth.connection() as db:
            return {"accepted_runs": db.execute("SELECT count(*) FROM ranked_runs WHERE result_fingerprint IS NOT NULL").fetchone()[0],
                    "best_entries": db.execute("SELECT count(*) FROM leaderboard_bests").fetchone()[0], "counts": faults.counts}

    print("LOCAL_FIXTURE_READY", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
