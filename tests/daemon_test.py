#!/usr/bin/python3
"""python3 tests/daemon_test.py -- omagramd's socket service with a fake TDLib and keyring.

The real event loop runs in a thread on a real Unix socket inside a sandbox under
$XDG_RUNTIME_DIR; nothing talks to Telegram or the real keyring."""
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"
sys.dont_write_bytecode = True
sys.path.insert(0, str(BIN))
import omagram_td as td  # noqa: E402
import plugin_safety as safe  # noqa: E402


def load_daemon():
    loader = importlib.machinery.SourceFileLoader("omagramd", str(BIN / "omagramd"))
    spec = importlib.util.spec_from_loader("omagramd", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def auth_update(kind, **fields):
    state = {"@type": kind}
    state.update(fields)
    return {"@type": "updateAuthorizationState", "authorization_state": state, "@client_id": 1}


class FakeTd:
    def __init__(self):
        self.client_id = 1
        self.sent = []
        self.daemon = None
        self.new_clients = 0

    def send(self, query):
        self.sent.append(query)
        if query.get("@type") == "close" and self.daemon is not None:
            self.daemon.events.put(auth_update("authorizationStateClosed"))
            self.daemon.wake()

    def receive(self, timeout):
        time.sleep(min(timeout, 0.02))
        return None

    def new_client(self):
        self.new_clients += 1
        self.client_id += 1
        return self.client_id

    def sent_types(self):
        return [q.get("@type") for q in self.sent]


class FakeKeyring:
    valid_credentials = staticmethod(td.valid_credentials)

    def __init__(self):
        self.credentials = None
        self.saved = []

    def load_credentials(self):
        return self.credentials

    def save_credentials(self, api_id, api_hash):
        self.saved.append((api_id, api_hash))
        self.credentials = (int(api_id), api_hash)
        return True

    def database_key(self):
        return "a" * 44

    def tdlib_parameters(self, api_id, api_hash, key, version):
        return {"@type": "setTdlibParameters", "api_id": api_id, "api_hash": api_hash, "database_encryption_key": key}


class Service(unittest.TestCase):
    HASH = "0123456789abcdef0123456789abcdef"

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="omagram-test-", dir=safe.runtime_dir()))
        os.chmod(self.root, 0o700)
        self.addCleanup(shutil.rmtree, self.root, True)
        self.d = load_daemon()
        for name, value in (("RUN", self.root), ("SOCKET", self.root / "omagram.sock"),
                            ("LOCK", self.root / "omagram.lock"), ("CLOSE_TIMEOUT", 2.0)):
            patch = mock.patch.object(self.d, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.fake = FakeTd()
        self.keyring = FakeKeyring()
        self.daemon = self.d.Daemon(open_client=lambda: self.fake, keyring=self.keyring)
        self.fake.daemon = self.daemon
        self.assertTrue(self.daemon.acquire())
        self.thread = threading.Thread(target=self.daemon.run, daemon=True)
        self.thread.start()
        self.wait(lambda: self.d.SOCKET.exists())
        self.addCleanup(self.stop)
        self.conns = []

    def stop(self):
        self.daemon.stop()
        self.thread.join(5)
        for conn in self.conns:
            conn.sock.close()

    def wait(self, predicate, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return True
            time.sleep(0.01)
        self.fail("condition not met in time")

    class Conn:
        """A client socket and what has been read from it but not consumed yet."""

        def __init__(self, sock):
            self.sock, self.buf = sock, b""

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(str(self.d.SOCKET))
        sock.settimeout(5)
        conn = self.Conn(sock)
        self.conns.append(conn)
        return conn

    def send(self, conn, value):
        conn.sock.sendall((value if isinstance(value, (bytes, bytearray)) else json.dumps(value).encode()) + b"\n")

    def read(self, conn, predicate):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            while b"\n" in conn.buf:
                line, _, conn.buf = conn.buf.partition(b"\n")
                value = json.loads(line)
                if predicate(value):
                    return value
            chunk = conn.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            conn.buf += chunk
        self.fail("no matching message")

    def request(self, conn, rid, cmd, **args):
        self.send(conn, {"id": rid, "cmd": cmd, "args": args})
        return self.read(conn, lambda v: v.get("id") == rid)

    def td_event(self, event):
        self.daemon.events.put(event)
        self.daemon.wake()

    def last_query(self, kind):
        self.wait(lambda: kind in self.fake.sent_types())
        return [q for q in self.fake.sent if q.get("@type") == kind][-1]

    def sign_in(self, conn):
        self.keyring.credentials = (12345, self.HASH)
        self.td_event(auth_update("authorizationStateReady"))
        self.read(conn, lambda v: v.get("event") == "auth" and v["auth"]["state"] == "ready")

    # ---------------------------------------------------------------- login

    def test_no_credentials_asks_for_them_and_credentials_start_tdlib(self):
        conn = self.connect()
        self.td_event(auth_update("authorizationStateWaitTdlibParameters"))
        self.assertEqual(self.read(conn, lambda v: v.get("event") == "auth")["auth"], {"state": "needCredentials"})
        self.assertEqual(self.request(conn, 1, "hello")["result"]["auth"], {"state": "needCredentials"})

        bad = self.request(conn, 2, "credentials.set", apiId="12x", apiHash=self.HASH)
        self.assertFalse(bad["ok"])
        bad = self.request(conn, 3, "credentials.set", apiId=12345, apiHash="short")
        self.assertFalse(bad["ok"])
        self.assertEqual(self.keyring.saved, [])

        ok = self.request(conn, 4, "credentials.set", apiId=12345, apiHash=self.HASH)
        self.assertEqual(ok, {"id": 4, "ok": True, "result": {}})
        self.assertNotIn(self.HASH, json.dumps(ok))
        self.assertEqual(self.keyring.saved, [("12345", self.HASH)])
        params = self.last_query("setTdlibParameters")
        self.assertEqual((params["api_id"], params["api_hash"]), (12345, self.HASH))

    def test_login_steps_reach_tdlib_and_errors_come_back_to_the_asker(self):
        conn = self.connect()
        self.td_event(auth_update("authorizationStateWaitPhoneNumber"))
        self.assertEqual(self.read(conn, lambda v: v.get("event") == "auth")["auth"], {"state": "phone"})
        self.send(conn, {"id": 5, "cmd": "auth.phone", "args": {"phone": "+380 (67) 123-45-67"}})
        query = self.last_query("setAuthenticationPhoneNumber")
        self.assertEqual(query["phone_number"], "+380671234567")
        self.td_event({"@type": "error", "code": 400, "message": "PHONE_NUMBER_INVALID", "@extra": query["@extra"], "@client_id": 1})
        answer = self.read(conn, lambda v: v.get("id") == 5)
        self.assertEqual((answer["ok"], answer["error"], answer["code"]), (False, "PHONE_NUMBER_INVALID", 400))

        for rid, cmd, args in ((6, "auth.phone", {"phone": "call me"}), (7, "auth.code", {"code": "12a45"}),
                               (8, "auth.password", {"password": ""}), (9, "auth.code", {"code": 12345})):
            self.assertFalse(self.request(conn, rid, cmd, **args)["ok"], cmd)

        self.send(conn, {"id": 10, "cmd": "auth.code", "args": {"code": "12345"}})
        query = self.last_query("checkAuthenticationCode")
        self.td_event({"@type": "ok", "@extra": query["@extra"], "@client_id": 1})
        self.assertEqual(self.read(conn, lambda v: v.get("id") == 10), {"id": 10, "ok": True, "result": {}})

        self.td_event(auth_update("authorizationStateWaitPassword", password_hint="cat"))
        self.assertEqual(self.read(conn, lambda v: v.get("event") == "auth")["auth"], {"state": "password", "hint": "cat"})
        self.send(conn, {"id": 11, "cmd": "auth.password", "args": {"password": "correct horse"}})
        self.assertEqual(self.last_query("checkAuthenticationPassword")["password"], "correct horse")

    def test_account_commands_need_a_signed_in_session(self):
        conn = self.connect()
        for rid, cmd in enumerate(("chats.load", "chat.history", "message.send", "auth.logout"), start=20):
            answer = self.request(conn, rid, cmd, chatId=1, text="x")
            self.assertEqual((answer["ok"], answer["error"]), (False, "not signed in"), cmd)
        self.assertNotIn("sendMessage", self.fake.sent_types())

    # ---------------------------------------------------------------- signed in

    def test_ready_loads_chats_and_updates_reach_every_client(self):
        a, b = self.connect(), self.connect()
        self.request(a, 1, "hello")
        self.request(b, 1, "hello")
        self.sign_in(a)
        self.last_query("loadChats")
        self.last_query("getMe")
        self.td_event({"@type": "updateNewChat", "@client_id": 1, "chat": {
            "@type": "chat", "id": 42, "title": "Friends", "type": {"@type": "chatTypeBasicGroup"},
            "positions": [{"@type": "chatPosition", "list": {"@type": "chatListMain"}, "order": "7"}]}})
        for conn in (a, b):
            event = self.read(conn, lambda v: v.get("event") == "chat")
            self.assertEqual((event["chat"]["id"], event["chat"]["title"]), (42, "Friends"))
        self.assertEqual([c["id"] for c in self.request(a, 2, "chats.list")["result"]["chats"]], [42])

    def test_history_send_edit_delete_and_read(self):
        conn = self.connect()
        self.sign_in(conn)
        self.send(conn, {"id": 30, "cmd": "chat.history", "args": {"chatId": 42, "limit": 20}})
        query = self.last_query("getChatHistory")
        self.assertEqual((query["chat_id"], query["limit"], query["from_message_id"]), (42, 20, 0))
        self.td_event({"@type": "messages", "@extra": query["@extra"], "@client_id": 1, "messages": [
            {"@type": "message", "id": 9, "chat_id": 42, "date": 1, "is_outgoing": True,
             "content": {"@type": "messageText", "text": {"text": "hello", "entities": []}}}, "junk"]})
        history = self.read(conn, lambda v: v.get("id") == 30)["result"]
        self.assertEqual([(m["id"], m["content"]["text"]) for m in history["messages"]], [(9, "hello")])

        self.send(conn, {"id": 31, "cmd": "message.send", "args": {"chatId": 42, "text": "hi there", "replyToMessageId": 9}})
        query = self.last_query("sendMessage")
        self.assertEqual(query["input_message_content"]["text"]["text"], "hi there")
        self.assertEqual(query["reply_to"]["message_id"], 9)
        self.assertFalse(self.request(conn, 32, "message.send", chatId=42, text="x" * 4097)["ok"])
        self.assertFalse(self.request(conn, 33, "message.send", chatId=42, text="")["ok"])

        self.send(conn, {"id": 34, "cmd": "message.edit", "args": {"chatId": 42, "messageId": 9, "text": "edited"}})
        self.assertEqual(self.last_query("editMessageText")["input_message_content"]["text"]["text"], "edited")
        self.send(conn, {"id": 35, "cmd": "message.delete", "args": {"chatId": 42, "messageIds": [9], "revoke": True}})
        self.assertEqual(self.last_query("deleteMessages")["message_ids"], [9])
        self.assertFalse(self.request(conn, 36, "message.delete", chatId=42, messageIds=[])["ok"])
        self.assertFalse(self.request(conn, 37, "message.delete", chatId=42, messageIds=[True])["ok"])
        self.send(conn, {"id": 38, "cmd": "chat.read", "args": {"chatId": 42, "messageIds": [9]}})
        self.assertTrue(self.last_query("viewMessages")["force_read"])

    def test_logout_starts_over_signed_out(self):
        conn = self.connect()
        self.sign_in(conn)
        self.td_event(auth_update("authorizationStateClosed"))
        self.assertEqual(self.read(conn, lambda v: v.get("event") == "auth")["auth"], {"state": "starting"})
        self.wait(lambda: self.fake.new_clients == 1)

    # ---------------------------------------------------------------- protocol safety

    def test_malformed_requests_get_errors_and_oversized_lines_disconnect(self):
        conn = self.connect()
        self.send(conn, b"not json")
        self.assertEqual(self.read(conn, lambda v: "error" in v)["id"], None)
        self.send(conn, b"[1, 2]")
        self.read(conn, lambda v: v.get("error") == "not a request")
        self.send(conn, {"id": "x", "cmd": "hello"})
        self.read(conn, lambda v: v.get("error") == "id must be an integer")
        self.assertEqual(self.request(conn, 1, "frobnicate")["error"], "unknown command")
        self.send(conn, {"id": 2, "cmd": "hello", "args": [1]})
        self.read(conn, lambda v: v.get("id") == 2 and v.get("error") == "unknown command")
        self.send(conn, b"x" * (self.d.LINE_MAX + 10))
        with self.assertRaises((ConnectionError, OSError)):
            self.read(conn, lambda v: False)
        self.assertTrue(self.request(self.connect(), 3, "hello")["ok"])

    def test_socket_and_directory_are_private(self):
        self.assertEqual(oct(os.stat(self.d.SOCKET).st_mode & 0o777), "0o600")
        self.assertEqual(oct(os.stat(self.root).st_mode & 0o777), "0o700")

    def test_only_one_instance(self):
        other = self.d.Daemon(open_client=lambda: FakeTd(), keyring=FakeKeyring())
        self.assertFalse(other.acquire())


class Startup(unittest.TestCase):
    def test_missing_library_is_reported_not_fatal(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix="omagram-test-", dir=safe.runtime_dir()))
        self.addCleanup(shutil.rmtree, root, True)
        d = load_daemon()

        def missing():
            raise td.TdUnavailable("TDLib is not built yet")
        daemon = d.Daemon(open_client=missing, keyring=FakeKeyring())
        daemon.start_td()
        self.assertEqual(daemon.auth, {"state": "noLibrary", "reason": "TDLib is not built yet"})

    def test_library_must_be_a_private_regular_file(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix="omagram-lib-", dir=safe.runtime_dir()))
        self.addCleanup(shutil.rmtree, root, True)
        os.chmod(root, 0o700)
        (root / "lib").mkdir(mode=0o700)
        lib = root / "lib" / "libtdjson.so"
        with self.assertRaisesRegex(td.TdUnavailable, "not built"):
            td.library_path(lib)
        lib.write_bytes(b"\x7fELF")
        os.chmod(lib, 0o644)
        self.assertEqual(td.library_path(lib), str(lib))
        os.chmod(lib, 0o666)
        with self.assertRaises(td.TdUnavailable):
            td.library_path(lib)
        lib.unlink()
        (root / "real.so").write_bytes(b"x")
        lib.symlink_to(root / "real.so")
        with self.assertRaises(td.TdUnavailable):
            td.library_path(lib)

    def test_credentials_validation(self):
        self.assertTrue(td.valid_credentials("123456", "0123456789abcdef0123456789abcdef"))
        for api_id, api_hash in (("0123", "0" * 32), ("12", "0" * 31), ("12", "G" * 32), (12, "0" * 32), ("12", None)):
            self.assertFalse(td.valid_credentials(api_id, api_hash), (api_id, api_hash))

    def test_database_key_is_never_invented_for_an_existing_database(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix="omagram-db-", dir=safe.runtime_dir()))
        self.addCleanup(shutil.rmtree, root, True)
        (root / "td.binlog").write_bytes(b"x")
        stored = []
        with mock.patch.object(td, "DATABASE", root), \
                mock.patch.object(td, "keyring_get", lambda key: (False, None)), \
                mock.patch.object(td, "keyring_set", lambda *a: stored.append(a) or True):
            with self.assertRaisesRegex(td.TdUnavailable, "missing"):
                td.database_key()
            self.assertEqual(stored, [])
            (root / "td.binlog").unlink()
            key = td.database_key()
            self.assertEqual(len(stored), 1)
            self.assertEqual(stored[0][2], key)

    def test_keyring_failures_are_not_mistaken_for_missing_secrets(self):
        with mock.patch.object(td.safe, "run", lambda argv, **kw: safe.Result(1, b"", b"", False, False)):
            self.assertEqual(td.keyring_get("api_id"), (False, None))
        with mock.patch.object(td.safe, "run", lambda argv, **kw: safe.Result(0, b"", b"", True, False)):
            with self.assertRaises(td.TdUnavailable):
                td.keyring_get("api_id")
        with mock.patch.object(td.safe, "run", lambda argv, **kw: safe.Result(4, b"", b"boom", False, False)):
            with self.assertRaises(td.TdUnavailable):
                td.keyring_get("api_id")

    def test_secrets_go_to_secret_tool_on_stdin_only(self):
        calls = []
        with mock.patch.object(td.safe, "run", lambda argv, **kw: calls.append((argv, kw)) or safe.Result(0, b"", b"", False, False)):
            self.assertTrue(td.save_credentials("123456", "0123456789abcdef0123456789abcdef"))
        for argv, kw in calls:
            self.assertNotIn("0123456789abcdef0123456789abcdef", " ".join(argv))
            self.assertNotIn("123456", [a for a in argv if not a.startswith("--label")])
        self.assertEqual([kw["input"] for _, kw in calls], ["123456", "0123456789abcdef0123456789abcdef"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
