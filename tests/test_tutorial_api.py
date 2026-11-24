"""Local HTTP regressions for account tutorial state."""

import asyncio
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import sys
from tempfile import TemporaryDirectory
from threading import Barrier
import unittest

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))

from app import SCHEMA, Settings, create_app
from leaderboards import TABLES as LEADERBOARD_TABLES


API = "/api/v1"
TUTORIAL = API + "/me/tutorial"
PASSWORD = "ExamplePass123"


class TutorialApiTests(unittest.TestCase):
    def setUp(self):
        if os.name == "nt":
            # Match the existing HTTP suite on restricted Windows hosts.
            policy = asyncio.get_event_loop_policy()
            asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
            self.addCleanup(asyncio.set_event_loop_policy, policy)
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.settings = Settings(database=Path(directory.name) / "accounts.sqlite3",
                                 secret=os.urandom(48).hex())
        self.delivered = []

    def start(self):
        def sender(*message):
            self.delivered.append(message)
            return "memory-message"

        self.app = create_app(self.settings, sender=sender, clock=lambda: 1_800_000_000)
        client = TestClient(self.app)
        self.addCleanup(client.close)
        return client

    def payload(self, response, status=200):
        self.assertEqual(response.status_code, status, response.text)
        return response.json()

    def register(self, client, email="new@example.com"):
        self.payload(client.post(API + "/auth/email-codes",
                                 json={"email": email, "purpose": "register"}), 202)
        self.app.state.auth.deliver_pending()
        _, _, code, challenge = self.delivered[-1]
        return self.payload(client.post(API + "/auth/register", json={
            "email": email, "password": PASSWORD, "code": code, "challenge_id": challenge,
        }), 201)

    @staticmethod
    def auth(session):
        return {"Authorization": "Bearer " + session["access_token"]}

    def test_pending_and_completed_are_visible_in_account_responses(self):
        client = self.start()
        session = self.register(client)
        user = session["user"]
        self.assertEqual(user["tutorial_state"], "pending")
        headers = self.auth(session)
        self.assertEqual(self.payload(client.get(API + "/me", headers=headers)), user)
        renamed = self.payload(client.patch(API + "/me", headers=headers, json={"username": "新玩家"}))
        self.assertEqual(renamed, {**user, "username": "新玩家"})
        for state in ("completed", "completed", "skipped"):
            self.assertEqual(self.payload(client.post(TUTORIAL, headers=headers, json={"state": state})),
                             {"tutorial_state": "completed"})

        client = self.start()
        expected = {**renamed, "tutorial_state": "completed"}
        login = self.payload(client.post(API + "/auth/login",
                                         json={"email": user["email"], "password": PASSWORD}))
        self.assertEqual(login["user"], expected)
        refresh = self.payload(client.post(API + "/auth/refresh",
                                           json={"refresh_token": login["refresh_token"]}))
        self.assertEqual(refresh["user"], expected)
        self.assertEqual(self.payload(client.get(API + "/me", headers=self.auth(refresh))), expected)
        patched = self.payload(client.patch(API + "/me", headers=self.auth(refresh),
                                            json={"username": "再次改名"}))
        self.assertEqual(patched, {**expected, "username": "再次改名"})

    def test_existing_accounts_are_exempt_across_migration_and_restart(self):
        for version in (1, 2, 3, 4):
            with self.subTest(version=version):
                self.settings = Settings(database=self.settings.database.with_name(f"v{version}.sqlite3"),
                                         secret=self.settings.secret)
                with closing(sqlite3.connect(self.settings.database)) as db, db:
                    db.executescript(SCHEMA)
                    db.execute("INSERT INTO users VALUES ('legacy','legacy@example.com','unused',1700000000)")
                    if version >= 2:
                        db.execute("ALTER TABLE users ADD COLUMN username TEXT NOT NULL DEFAULT '旧玩家'")
                    if version == 4:
                        for statement in LEADERBOARD_TABLES:
                            db.execute(statement)
                    db.execute("UPDATE schema_version SET version=?", (version,))

                self.start()
                service = self.app.state.auth
                with service.transaction() as db:
                    session = service.new_session(db, {"id": "legacy"})
                    self.assertEqual(db.execute("SELECT version FROM schema_version").fetchone()[0], 5)
                self.assertEqual(session["user"]["tutorial_state"], "exempt")
                client = self.start()
                headers = self.auth(session)
                for state in ("completed", "skipped"):
                    self.assertEqual(self.payload(client.post(TUTORIAL, headers=headers, json={"state": state})),
                                     {"tutorial_state": "exempt"})
                self.assertEqual(self.payload(client.get(API + "/me", headers=headers))["tutorial_state"], "exempt")

    def test_authentication_validation_and_account_isolation(self):
        client = self.start()
        alice = self.auth(self.register(client, "alice@example.com"))
        bob = self.auth(self.register(client, "bob@example.com"))
        self.payload(client.post(TUTORIAL, json={"state": "skipped"}), 401)
        for body in ({}, {"state": None}, {"state": "pending"}, {"state": "exempt"},
                     {"state": "SKIPPED"}, {"state": "skipped", "user_id": "bob"}):
            with self.subTest(body=body):
                self.payload(client.post(TUTORIAL, headers=alice, json=body), 422)
        self.assertEqual(self.payload(client.get(API + "/me", headers=alice))["tutorial_state"], "pending")
        for state in ("skipped", "completed"):
            self.assertEqual(self.payload(client.post(TUTORIAL, headers=alice, json={"state": state})),
                             {"tutorial_state": "skipped"})
        self.assertEqual(self.payload(client.get(API + "/me", headers=bob))["tutorial_state"], "pending")

    def test_concurrent_conflicting_outcomes_return_one_winner(self):
        first = self.start()
        headers = self.auth(self.register(first))
        second = self.start()
        barrier = Barrier(2, timeout=10)

        def submit(client, state):
            barrier.wait()
            return client.post(TUTORIAL, headers=headers, json={"state": state})

        with ThreadPoolExecutor(max_workers=2) as pool:
            complete = pool.submit(submit, first, "completed")
            skip = pool.submit(submit, second, "skipped")
            winner = self.payload(complete.result())
            self.assertEqual(self.payload(skip.result()), winner)
        self.assertIn(winner["tutorial_state"], ("completed", "skipped"))
        profile = self.payload(first.get(API + "/me", headers=headers))
        self.assertEqual(profile["tutorial_state"], winner["tutorial_state"])
