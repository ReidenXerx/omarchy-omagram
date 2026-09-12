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


class Harness(unittest.TestCase):
    """A running service on a sandboxed socket, and helpers; no tests of its own."""

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
        for name, value in (("REC", self.root / "rec"), ("SENT", self.root / "sent")):
            patch = mock.patch.object(self.d.media, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        for name, value in (("CONFIG", self.root / "config"), ("SETTINGS", self.root / "config" / "settings.json")):
            patch = mock.patch.object(self.d.prefs, name, value)
            patch.start()
            self.addCleanup(patch.stop)

        def no_hyprctl(args):
            raise AssertionError("tests never run the real hyprctl")
        patch = mock.patch.object(self.d.prefs, "hyprctl", no_hyprctl)
        patch.start()
        self.addCleanup(patch.stop)
        self.fake = FakeTd()
        self.keyring = FakeKeyring()
        self.daemon = self.d.Daemon(open_client=lambda: self.fake, keyring=self.keyring,
                                    notifier_factory=lambda on_action: self.d.notify.Notifier(FakeNotifierTransport, on_action))
        self.fake.daemon = self.daemon
        self.assertTrue(self.daemon.acquire())
        self.thread = threading.Thread(target=self.daemon.run, daemon=True)
        self.thread.start()
        self.wait(self.accepting)
        self.addCleanup(self.stop)
        self.conns = []

    def accepting(self):
        # The socket file exists a moment before listen(); only a real connection proves it.
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(self.d.SOCKET))
            return True
        except OSError:
            return False
        finally:
            probe.close()

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
        # connect() returns once the kernel queues the connection, which can be before the
        # service has accepted it; an event broadcast in between would reach nobody. A
        # hello round trip proves the service knows this client.
        self.request(conn, 999999, "hello")
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


class Service(Harness):
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
        me = self.last_query("getMe")
        # The service's own request: its answer is kept, not sent to a socket as a response.
        self.td_event({"@type": "user", "id": 777, "first_name": "Me", "@extra": me["@extra"], "@client_id": 1})
        self.assertEqual(self.read(a, lambda v: v.get("event") == "me")["meId"], 777)
        self.assertEqual(self.request(b, 5, "hello")["result"]["meId"], 777)
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


class MediaCommands(Harness):
    def setUp(self):
        super().setUp()
        self.files = self.root / "files"
        (self.files / "stickers").mkdir(parents=True, mode=0o700)
        self.daemon.state.files_root = str(self.files)
        patch = mock.patch.object(self.d, "LOTTIE", self.root / "lottie")
        patch.start()
        self.addCleanup(patch.stop)
        self.conn = self.connect()
        self.sign_in(self.conn)

    def file_event(self, extra, fid, path, done=True):
        return {"@type": "file", "id": fid, "size": 10, "expected_size": 10, "@extra": extra, "@client_id": 1,
                "local": {"@type": "localFile", "path": str(path), "is_downloading_completed": done,
                          "is_downloading_active": not done, "downloaded_size": 10 if done else 0}}

    def lottie(self, rid, path, done=True):
        self.send(self.conn, {"id": rid, "cmd": "sticker.lottie", "args": {"fileId": 9}})
        query = self.last_query("getFile")
        self.fake.sent.clear()
        self.td_event(self.file_event(query["@extra"], 9, path, done))
        return self.read(self.conn, lambda v: v.get("id") == rid)

    def test_download_request_and_answer(self):
        self.send(self.conn, {"id": 40, "cmd": "file.download", "args": {"fileId": 5}})
        query = self.last_query("downloadFile")
        self.assertEqual((query["file_id"], query["priority"], query["synchronous"]), (5, 16, False))
        self.td_event(self.file_event(query["@extra"], 5, "", done=False))
        answer = self.read(self.conn, lambda v: v.get("id") == 40)
        self.assertEqual((answer["result"]["id"], answer["result"]["path"], answer["result"]["active"]), (5, "", True))
        for args in ({"fileId": 0}, {"fileId": "5"}, {"fileId": 5, "priority": 99}):
            self.assertFalse(self.request(self.conn, 41, "file.download", **args)["ok"], args)

    def test_tgs_sticker_becomes_cached_lottie_json(self):
        import gzip
        animation = b'{"v":"5.5.2","fr":60,"layers":[]}'
        tgs = self.files / "stickers" / "a.tgs"
        tgs.write_bytes(gzip.compress(animation))
        path = self.lottie(50, tgs)["result"]["path"]
        self.assertTrue(path.startswith(str(self.root / "lottie")) and path.endswith(".json"))
        self.assertEqual(pathlib.Path(path).read_bytes(), animation)
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")
        self.assertEqual(self.lottie(51, tgs)["result"]["path"], path)   # cached by content

    def test_hostile_or_foreign_stickers_are_refused(self):
        import gzip
        cases = {
            "bomb": gzip.compress(b"{" + b" " * (self.d.LOTTIE_MAX + 10) + b"}"),
            "not gzip": b'{"v":"5.5.2"}',
            "not json": gzip.compress(b"\x00\x01binary"),
            "json array": gzip.compress(b"[1, 2, 3]"),
            "oversized": b"\x1f\x8b" + os.urandom(self.d.TGS_MAX + 10),
        }
        for rid, (name, blob) in enumerate(cases.items(), start=60):
            target = self.files / "stickers" / (name.replace(" ", "-") + ".tgs")
            target.write_bytes(blob)
            self.assertEqual(self.lottie(rid, target)["result"]["path"], "", name)
        outside = self.root / "elsewhere.tgs"
        outside.write_bytes(gzip.compress(b'{"v":"5.5.2"}'))
        self.assertEqual(self.lottie(70, outside)["result"]["path"], "")
        self.assertEqual(self.lottie(71, self.files / "stickers" / "a.tgs", done=False)["result"]["path"], "")
        self.assertFalse((self.root / "lottie").exists() and any((self.root / "lottie").iterdir()))

    def test_file_progress_reaches_clients(self):
        self.td_event({"@type": "updateFile", "@client_id": 1, "file": {
            "@type": "file", "id": 77, "size": 10, "expected_size": 10,
            "local": {"@type": "localFile", "path": str(self.files / "stickers" / "x.webp"),
                      "is_downloading_completed": True, "downloaded_size": 10}}})
        event = self.read(self.conn, lambda v: v.get("event") == "file")
        self.assertEqual((event["file"]["id"], event["file"]["path"]), (77, str(self.files / "stickers" / "x.webp")))


class Sending(Harness):
    def setUp(self):
        super().setUp()
        self.conn = self.connect()
        self.sign_in(self.conn)
        self.uploads = self.root / "uploads"
        self.uploads.mkdir(mode=0o700)

    def file(self, name, size=1000):
        path = self.uploads / name
        with path.open("wb") as f:
            f.truncate(size)
        return path

    def sent(self, rid, **args):
        self.send(self.conn, {"id": rid, "cmd": "message.sendFile", "args": args})
        query = self.last_query("sendMessage")
        self.fake.sent.clear()
        return query

    def test_images_go_as_photos_everything_else_as_documents(self):
        photo = self.file("cat.JPG", 200_000)
        q = self.sent(1, chatId=42, path=str(photo), caption="look", replyToMessageId=9)
        content = q["input_message_content"]
        self.assertEqual((content["@type"], content["photo"]["photo"], content["caption"]["text"], q["reply_to"]["message_id"]),
                         ("inputMessagePhoto", {"@type": "inputFileLocal", "path": str(photo)}, "look", 9))
        big = self.file("huge.png", self.d.PHOTO_MAX + 1)
        self.assertEqual(self.sent(2, chatId=42, path=str(big))["input_message_content"]["@type"], "inputMessageDocument")
        pdf = self.file("report.pdf")
        self.assertEqual(self.sent(3, chatId=42, path=str(pdf))["input_message_content"]["document"]["document"]["path"], str(pdf))
        self.assertEqual(self.sent(4, chatId=42, path=str(photo), asPhoto=False)["input_message_content"]["@type"], "inputMessageDocument")
        link = self.uploads / "link.jpg"
        link.symlink_to(photo)
        self.assertEqual(self.sent(5, chatId=42, path=str(link))["input_message_content"]["photo"]["photo"]["path"], str(photo))

    def test_what_cannot_be_sent_is_refused_before_tdlib_sees_it(self):
        empty = self.file("empty.txt", 0)
        too_big = self.file("disk.img", self.d.DOCUMENT_MAX + 1)
        database = self.root / "database"
        database.mkdir(mode=0o700)
        (database / "td.binlog").write_bytes(b"x")
        cases = {
            "relative": "uploads/cat.jpg", "missing": str(self.uploads / "nope.jpg"), "directory": str(self.uploads),
            "empty": str(empty), "too big": str(too_big), "control characters": str(self.uploads) + "/a\nb",
            "database": str(database / "td.binlog"), "not text": 5,
        }
        with mock.patch.object(self.d.td, "DATABASE", database):
            for rid, (name, path) in enumerate(cases.items(), start=10):
                answer = self.request(self.conn, rid, "message.sendFile", chatId=42, path=path)
                self.assertFalse(answer["ok"], name)
        self.assertFalse(self.request(self.conn, 30, "message.sendFile", chatId=42, path=str(self.file("a.jpg")),
                                      caption="x" * 1025)["ok"])
        self.assertNotIn("sendMessage", self.fake.sent_types())

    def test_stickers_are_sent_by_file_id(self):
        self.send(self.conn, {"id": 40, "cmd": "message.sendSticker", "args": {"chatId": 42, "fileId": 77, "width": 512, "height": 512, "emoji": "😂"}})
        content = self.last_query("sendMessage")["input_message_content"]
        self.assertEqual((content["@type"], content["sticker"]["sticker"], content["sticker"]["width"], content["emoji"]),
                         ("inputMessageSticker", {"@type": "inputFileId", "id": 77}, 512, "😂"))
        for args in ({"chatId": 42, "fileId": 0}, {"chatId": 42, "fileId": 5, "emoji": "x" * 40}, {"chatId": 42, "fileId": 5, "width": -1}):
            self.assertFalse(self.request(self.conn, 41, "message.sendSticker", **args)["ok"], args)

    def sticker(self, fid):
        return {"@type": "sticker", "id": "1", "set_id": "2", "width": 512, "height": 512, "emoji": "🙂",
                "format": {"@type": "stickerFormatWebp"},
                "sticker": {"@type": "file", "id": fid, "size": 100, "local": {"@type": "localFile", "path": "", "is_downloading_completed": False}}}

    def test_recent_stickers_sets_and_a_set(self):
        self.send(self.conn, {"id": 50, "cmd": "stickers.recent"})
        q = self.last_query("getRecentStickers")
        self.td_event({"@type": "stickers", "@extra": q["@extra"], "@client_id": 1, "stickers": [self.sticker(5), "junk", self.sticker(6)]})
        recent = self.read(self.conn, lambda v: v.get("id") == 50)["result"]["stickers"]
        self.assertEqual([s["file"]["id"] for s in recent], [5, 6])

        self.send(self.conn, {"id": 51, "cmd": "stickers.sets"})
        q = self.last_query("getInstalledStickerSets")
        self.assertEqual(q["sticker_type"], {"@type": "stickerTypeRegular"})
        self.td_event({"@type": "stickerSets", "@extra": q["@extra"], "@client_id": 1, "sets": [
            {"@type": "stickerSetInfo", "id": "9223372036854775807", "title": "Pandas", "size": 30, "covers": [self.sticker(7)]}]})
        sets = self.read(self.conn, lambda v: v.get("id") == 51)["result"]["sets"]
        self.assertEqual((sets[0]["id"], sets[0]["title"], sets[0]["cover"]["file"]["id"]), ("9223372036854775807", "Pandas", 7))

        self.send(self.conn, {"id": 52, "cmd": "stickers.set", "args": {"setId": "9223372036854775807"}})
        q = self.last_query("getStickerSet")
        self.assertEqual(q["set_id"], 9223372036854775807)
        self.td_event({"@type": "stickerSet", "@extra": q["@extra"], "@client_id": 1, "title": "Pandas", "stickers": [self.sticker(8)]})
        one = self.read(self.conn, lambda v: v.get("id") == 52)["result"]
        self.assertEqual((one["title"], [s["file"]["id"] for s in one["stickers"]]), ("Pandas", [8]))
        for bad in (123, "12a", ""):
            self.assertFalse(self.request(self.conn, 53, "stickers.set", setId=bad)["ok"], bad)


class ListsAndSearch(Harness):
    def setUp(self):
        super().setUp()
        self.conn = self.connect()
        self.sign_in(self.conn)
        self.td_event({"@type": "updateNewChat", "@client_id": 1, "chat": {
            "@type": "chat", "id": 42, "title": "Friends", "type": {"@type": "chatTypeBasicGroup"},
            "positions": [{"@type": "chatPosition", "list": {"@type": "chatListMain"}, "order": "7"}]}})
        self.read(self.conn, lambda v: v.get("event") == "chat")

    def call(self, rid, cmd, kind, result, **args):
        """Send a command, answer the TDLib query it makes, return (query, reply)."""
        before = self.fake.sent_types().count(kind)
        self.send(self.conn, {"id": rid, "cmd": cmd, "args": args})
        self.wait(lambda: self.fake.sent_types().count(kind) > before)
        query = [q for q in self.fake.sent if q.get("@type") == kind][-1]
        self.td_event(dict(result, **{"@extra": query["@extra"], "@client_id": 1}))
        return query, self.read(self.conn, lambda v: v.get("id") == rid)

    def test_folders_reach_the_ui_and_a_window_hello(self):
        self.td_event({"@type": "updateChatFolders", "@client_id": 1, "main_chat_list_position": 0, "chat_folders": [
            {"@type": "chatFolderInfo", "id": 3, "name": {"text": {"text": "Work"}}, "icon": {"name": "Work"}}]})
        event = self.read(self.conn, lambda v: v.get("event") == "folders")
        self.assertEqual(event["folders"], [{"id": 3, "name": "Work", "icon": "Work"}])
        bar = self.request(self.conn, 1, "hello")["result"]
        self.assertEqual((bar["folders"][0]["id"], "allChats" in bar), (3, False))
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(str(self.d.SOCKET))
        sock.settimeout(5)
        window = self.Conn(sock)
        self.conns.append(window)
        result = self.request(window, 2, "hello", window=True)["result"]
        self.assertEqual([c["id"] for c in result["allChats"]], [42])

    def test_lists_load_by_key_and_bad_keys_are_refused(self):
        query, reply = self.call(10, "chats.load", "loadChats", {"@type": "ok"}, list="folder:3", limit=50)
        self.assertEqual((query["chat_list"], query["limit"], reply["result"]["list"]),
                         ({"@type": "chatListFolder", "chat_folder_id": 3}, 50, "folder:3"))
        query, _ = self.call(11, "chats.load", "loadChats", {"@type": "ok"}, list="archive")
        self.assertEqual(query["chat_list"], {"@type": "chatListArchive"})
        for rid, bad in enumerate(("folder:0", "folder:99999999999", "folder:-1", "main;rm", 5), start=12):
            self.assertFalse(self.request(self.conn, rid, "chats.load", list=bad)["ok"], bad)
        self.assertEqual(self.request(self.conn, 20, "chats.list", list="main")["result"]["chats"][0]["id"], 42)

    def test_chat_search_local_and_on_the_server(self):
        query, reply = self.call(30, "chats.search", "searchChats", {"@type": "chats", "total_count": 2,
                                                                     "chat_ids": [42, 999]}, query="fri")
        self.assertEqual((query["query"], query["type_filter"], query["limit"]), ("fri", None, 30))
        self.assertEqual([c["id"] for c in reply["result"]["chats"]], [42])   # unknown ids are skipped
        query, reply = self.call(31, "chats.search", "searchChatsOnServer", {"@type": "chats", "chat_ids": []},
                                 query="fri", server=True, limit=5)
        self.assertEqual((query["limit"], reply["result"]["server"]), (5, True))
        self.assertFalse(self.request(self.conn, 32, "chats.search", query="")["ok"])
        self.assertFalse(self.request(self.conn, 33, "chats.search", query="x" * 300)["ok"])

    def test_message_search_everywhere_and_in_one_chat(self):
        found = {"@type": "message", "id": 500, "chat_id": 42, "date": 1, "is_outgoing": False,
                 "sender_id": {"@type": "messageSenderChat", "chat_id": 42},
                 "content": {"@type": "messageText", "text": {"text": "lunch?", "entities": []}}}
        query, reply = self.call(40, "messages.search", "searchMessages",
                                 {"@type": "foundMessages", "total_count": 1, "messages": [found, "junk"],
                                  "next_offset": "abc"}, query="lunch")
        self.assertEqual({k: query[k] for k in ("chat_list", "offset", "filter", "chat_type_filter", "min_date")},
                         {"chat_list": None, "offset": "", "filter": None, "chat_type_filter": None, "min_date": 0})
        result = reply["result"]
        self.assertEqual(([m["id"] for m in result["messages"]], result["nextOffset"], result["chatId"]),
                         ([500], "abc", 0))
        query, reply = self.call(41, "messages.search", "searchChatMessages",
                                 {"@type": "foundChatMessages", "total_count": 1, "messages": [found],
                                  "next_from_message_id": 480}, query="lunch", chatId=42, fromMessageId=900, limit=10)
        self.assertEqual({k: query[k] for k in ("chat_id", "from_message_id", "limit", "sender_id", "topic_id")},
                         {"chat_id": 42, "from_message_id": 900, "limit": 10, "sender_id": None, "topic_id": None})
        self.assertEqual(reply["result"]["nextFromMessageId"], 480)
        self.assertFalse(self.request(self.conn, 42, "messages.search", query="a", offset=5)["ok"])
        self.assertFalse(self.request(self.conn, 43, "messages.search", query="a", chatId="42")["ok"])

    def test_hostile_lines_get_an_error_and_the_service_lives(self):
        self.send(self.conn, b"[" * 60000)
        self.assertFalse(self.read(self.conn, lambda v: v.get("id") is None)["ok"])
        self.send(self.conn, b'{"id": 60, "cmd": "chats.search", "args": {"query": "\\ud800"}}')
        self.assertFalse(self.read(self.conn, lambda v: v.get("id") in (60, None))["ok"])
        with mock.patch.object(self.d.Daemon, "cmd_chat_list", side_effect=RuntimeError("boom")):
            self.assertFalse(self.request(self.conn, 61, "chats.list")["ok"])
        self.assertTrue(self.request(self.conn, 62, "chats.list")["ok"])
        self.assertFalse(self.request(self.conn, 63, "chat.pin", chatId=10 ** 30, pinned=True)["ok"])
        self.assertTrue(self.thread.is_alive())

    def test_pin_and_archive(self):
        query, reply = self.call(50, "chat.pin", "toggleChatIsPinned", {"@type": "ok"}, chatId=42, pinned=True)
        self.assertEqual((query["chat_list"], query["chat_id"], query["is_pinned"], reply["ok"]),
                         ({"@type": "chatListMain"}, 42, True, True))
        query, _ = self.call(51, "chat.pin", "toggleChatIsPinned", {"@type": "ok"}, chatId=42, pinned=False,
                             list="folder:3")
        self.assertEqual(query["chat_list"], {"@type": "chatListFolder", "chat_folder_id": 3})
        query, _ = self.call(52, "chat.archive", "addChatToList", {"@type": "ok"}, chatId=42, archived=True)
        self.assertEqual(query["chat_list"], {"@type": "chatListArchive"})
        # the archive is loaded next, or the moved chat would have no position to be shown at
        self.wait(lambda: any(q.get("@type") == "loadChats" and q.get("chat_list") == {"@type": "chatListArchive"}
                              for q in self.fake.sent))
        query, _ = self.call(53, "chat.archive", "addChatToList", {"@type": "ok"}, chatId=42, archived=False)
        self.assertEqual(query["chat_list"], {"@type": "chatListMain"})
        self.assertFalse(self.request(self.conn, 54, "chat.pin", chatId=42, pinned="yes")["ok"])
        self.assertFalse(self.request(self.conn, 55, "chat.archive", chatId=42)["ok"])


class Recording(Harness):
    """Voice and video messages with the recorder and converter faked: no microphone,
    camera or ffmpeg is used."""

    def setUp(self):
        super().setUp()
        self.conn = self.connect()
        self.sign_in(self.conn)
        recorder = [sys.executable, "-c",
                    "import signal, sys, time; signal.signal(signal.SIGINT, lambda *a: sys.exit(0)); time.sleep(30)"]

        def voice_argv(path):
            pathlib.Path(path).write_bytes(b"OggS")
            return recorder

        def prepare_video_note(source, target):
            pathlib.Path(target).write_bytes(b"mp4")
            return 7.4
        for name, value in (("voice_argv", voice_argv), ("prepare_voice", lambda path: (3, "AAAA")),
                            ("prepare_video_note", prepare_video_note)):
            patch = mock.patch.object(self.d.media, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def sent_after(self, before):
        self.wait(lambda: self.fake.sent_types().count("sendMessage") > before)
        return [q for q in self.fake.sent if q.get("@type") == "sendMessage"][-1]

    def test_a_voice_message_is_recorded_and_sent(self):
        self.assertTrue(self.request(self.conn, 1, "voice.start", chatId=42)["ok"])
        self.read(self.conn, lambda v: v.get("event") == "recording" and v.get("state") == "voice")
        self.assertFalse(self.request(self.conn, 2, "voice.start", chatId=42)["ok"])   # one at a time
        path = str(self.daemon.recording["path"])
        self.assertEqual(os.path.dirname(path), str(self.d.media.SENT), "kept: the chat plays it from there")
        before = self.fake.sent_types().count("sendMessage")
        self.send(self.conn, {"id": 3, "cmd": "voice.stop", "args": {"send": True, "replyToMessageId": 9}})
        query = self.sent_after(before)
        self.assertEqual(query["chat_id"], 42)
        self.assertEqual(query["reply_to"]["message_id"], 9)
        self.assertEqual(query["input_message_content"]["voice_note"],
                         {"@type": "inputVoiceNote", "voice_note": {"@type": "inputFileLocal", "path": path},
                          "duration": 3, "waveform": "AAAA"})
        self.read(self.conn, lambda v: v.get("event") == "recording" and v.get("state") == "idle")
        self.wait(lambda: self.daemon.recording is None and self.daemon.jobs == 0)

    def test_a_cancelled_voice_message_is_deleted(self):
        self.assertTrue(self.request(self.conn, 1, "voice.start", chatId=42)["ok"])
        path = pathlib.Path(self.daemon.recording["path"])
        self.assertTrue(path.exists())
        self.assertTrue(self.request(self.conn, 2, "voice.stop", send=False)["ok"])
        self.assertFalse(path.exists())
        self.assertNotIn("sendMessage", self.fake.sent_types())
        self.assertFalse(self.request(self.conn, 3, "voice.stop", send=False)["ok"])   # nothing recording
        self.assertFalse(self.request(self.conn, 4, "voice.start", chatId="42")["ok"])

    def test_a_video_message_only_from_the_recording_directory(self):
        rec = self.d.media.rec_dir()
        source = rec / "note-1.mp4"
        source.write_bytes(b"recorded")
        before = self.fake.sent_types().count("sendMessage")
        self.send(self.conn, {"id": 5, "cmd": "videonote.send", "args": {"chatId": 42, "path": str(source)}})
        note = self.sent_after(before)["input_message_content"]["video_note"]
        self.assertEqual((note["duration"], note["length"], note["thumbnail"]), (7, self.d.media.NOTE_SIZE, None))
        self.assertEqual(os.path.dirname(note["video_note"]["path"]), str(self.d.media.SENT))
        self.wait(lambda: not source.exists())   # the raw recording goes once converted
        outside = self.root / "elsewhere.mp4"
        outside.write_bytes(b"x")
        link = rec / "link.mp4"
        link.symlink_to(outside)
        for rid, bad in enumerate((str(outside), str(link), "note-1.mp4", 7), start=6):
            self.assertFalse(self.request(self.conn, rid, "videonote.send", chatId=42, path=bad)["ok"], bad)
            self.assertFalse(self.request(self.conn, rid + 100, "videonote.discard", path=bad)["ok"], bad)
        self.assertTrue(outside.exists())
        keep = rec / "note-2.mp4"
        keep.write_bytes(b"x")
        self.assertTrue(self.request(self.conn, 20, "videonote.discard", path=str(keep))["ok"])
        self.assertFalse(keep.exists())


class Settings(Harness):
    def setUp(self):
        super().setUp()
        self.applied = []

        def apply(desired):
            self.applied.append(dict(desired))
            return {a: ("active" if a in desired else "off") for a in self.d.prefs.GLOBALS}
        patch = mock.patch.object(self.d.prefs, "apply", apply)
        patch.start()
        self.addCleanup(patch.stop)
        patch = mock.patch.dict(os.environ, {"HYPRLAND_INSTANCE_SIGNATURE": "test"})
        patch.start()
        self.addCleanup(patch.stop)
        self.conn = self.connect()

    def test_settings_come_with_hello_and_are_saved_and_shared(self):
        hello = self.request(self.conn, 1, "hello")["result"]
        self.assertEqual(hello["settings"], {"shortcuts": {}, "globalShortcuts": {}})
        self.assertEqual(hello["globalStatus"]["global.quickReply"], "off")
        other = self.connect()
        answer = self.request(self.conn, 2, "settings.set", settings={"shortcuts": {"window.voice": ["Ctrl+Alt+V"]}})
        self.assertTrue(answer["ok"], answer)
        event = self.read(other, lambda v: v.get("event") == "settings")
        self.assertEqual(event["settings"]["shortcuts"], {"window.voice": ["Ctrl+Alt+V"]})
        saved = json.loads(self.d.prefs.SETTINGS.read_text())
        self.assertEqual(saved["shortcuts"], {"window.voice": ["Ctrl+Alt+V"]})
        self.assertEqual(self.applied, [], "no global shortcut changed, nothing registered")
        self.assertFalse(self.request(self.conn, 3, "settings.set", settings={"shortcuts": {"Bad Id": ["A"]}})["ok"])
        self.assertFalse(self.request(self.conn, 4, "settings.set", settings="junk")["ok"])
        self.assertEqual(json.loads(self.d.prefs.SETTINGS.read_text())["shortcuts"], {"window.voice": ["Ctrl+Alt+V"]})

    def test_global_shortcuts_are_registered_and_registered_again(self):
        answer = self.request(self.conn, 5, "settings.set",
                              settings={"globalShortcuts": {"global.quickReply": "super+alt+m"}})
        self.assertEqual(answer["result"]["globalStatus"]["global.quickReply"], "active")
        self.assertEqual(self.applied, [{"global.quickReply": "SUPER + ALT + M"}])
        self.assertTrue(self.request(self.conn, 6, "shortcuts.apply")["ok"])
        self.assertEqual(len(self.applied), 2)
        self.request(self.conn, 7, "settings.set", settings={"globalShortcuts": {"global.quickReply": "SUPER + ALT + M"}})
        self.assertEqual(len(self.applied), 2, "unchanged: not registered again")

    def test_without_hyprland_nothing_is_registered(self):
        with mock.patch.dict(os.environ, {"HYPRLAND_INSTANCE_SIGNATURE": ""}):
            answer = self.request(self.conn, 8, "settings.set", settings={"globalShortcuts": {"global.panel": "SUPER + P"}})
        self.assertEqual(answer["result"]["globalStatus"]["global.panel"], "unavailable")
        self.assertEqual(self.applied, [])


class FakeNotifierTransport:
    """The bus, faked. Clicks are queued and delivered from pump(), on the service's own
    thread, the way Gio delivers real signals."""

    def __init__(self, on_action, on_closed):
        self.on_action, self.on_closed = on_action, on_closed
        self.shown, self.closed, self.clicks, self.next_id = [], [], [], 0

    def notify(self, replaces, title, body, actions, hints):
        self.shown.append((title, body))
        self.next_id += 1
        return replaces or self.next_id

    def close(self, nid):
        self.closed.append(nid)

    def pump(self):
        while self.clicks:
            self.on_action(*self.clicks.pop(0))


class Notifications(Harness):
    def setUp(self):
        super().setUp()
        self.bus = self.daemon.notifier.transport
        self.spawned = []
        self.daemon.spawn = lambda argv, fallback=None, timeout=None: self.spawned.append((argv, fallback))
        self.conn = self.connect()
        self.sign_in(self.conn)
        self.td_event({"@type": "updateNewChat", "@client_id": 1, "chat": {
            "@type": "chat", "id": 42, "title": "Friends", "type": {"@type": "chatTypeBasicGroup"},
            "positions": [{"@type": "chatPosition", "list": {"@type": "chatListMain"}, "order": "7"}]}})
        self.td_event({"@type": "updateUser", "@client_id": 1, "user": {"@type": "user", "id": 7, "first_name": "Ann"}})
        self.settle()

    def group(self, added=(), total=1, removed=()):
        return {"@type": "updateNotificationGroup", "@client_id": 1, "notification_group_id": 3, "chat_id": 42,
                "total_count": total, "added_notifications": list(added), "removed_notification_ids": list(removed)}

    def note(self, nid, text, silent=False, preview=True):
        return {"@type": "notification", "id": nid, "date": 1, "is_silent": silent, "type": {
            "@type": "notificationTypeNewMessage", "show_preview": preview, "message": {
                "@type": "message", "id": nid * 10, "chat_id": 42, "date": 1, "is_outgoing": False,
                "sender_id": {"@type": "messageSenderUser", "user_id": 7},
                "content": {"@type": "messageText", "text": {"text": text, "entities": []}}}}}

    def settle(self):
        # The service answers sockets before it drains TDLib's queue, so a request round trip
        # proves nothing about events; a marker event sent through the same queue does.
        self.marks = getattr(self, "marks", 0) + 1
        marker = f"settle-{self.marks}"
        self.td_event({"@type": "updateUser", "@client_id": 1, "user": {"@type": "user", "id": 900 + self.marks,
                                                                         "first_name": marker}})
        self.read(self.conn, lambda v: v.get("event") == "user" and marker in json.dumps(v))

    def click(self, action):
        self.bus.clicks.append((self.daemon.notifier.by_chat[42], action))
        self.daemon.wake()

    def window(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(str(self.d.SOCKET))
        sock.settimeout(5)
        conn = self.Conn(sock)
        self.conns.append(conn)
        return conn, self.request(conn, 1, "hello", window=True)["result"]["open"]

    def test_sign_in_turns_on_tdlib_notifications(self):
        query = self.last_query("setOption")
        self.assertEqual(query["name"], "notification_group_count_max")
        self.assertGreater(query["value"]["value"], 0)

    def test_new_messages_notify_and_reads_withdraw(self):
        self.td_event(self.group([self.note(1, "hi <b>there</b>")], total=2))
        self.settle()
        self.assertEqual(self.bus.shown, [("Friends (2)", "Ann: hi &lt;b&gt;there&lt;/b&gt;")])
        self.td_event(self.group([self.note(2, "quiet", silent=True)]))
        self.td_event(self.group([self.note(3, "secret", preview=False)]))
        self.settle()
        self.assertEqual(self.bus.shown[1:], [("Friends", "New message")])
        self.td_event(self.group(total=0, removed=[1, 3]))
        self.settle()
        self.assertEqual(self.bus.closed, [1])

    def test_the_chat_being_read_stays_quiet(self):
        self.assertTrue(self.request(self.conn, 60, "ui.focus", chatId=42)["ok"])
        self.td_event(self.group([self.note(1, "hi")]))
        self.settle()
        self.assertEqual(self.bus.shown, [])
        self.request(self.conn, 61, "ui.focus", chatId=0)
        self.td_event(self.group([self.note(2, "hi")]))
        self.settle()
        self.assertEqual(len(self.bus.shown), 1)

    def launched_window(self):
        return [argv for argv, _ in self.spawned if argv[-1].endswith("/omagram")]

    def test_open_starts_the_window_which_opens_the_chat(self):
        self.td_event(self.group([self.note(1, "hi")]))
        self.settle()
        self.click("default")
        self.wait(self.launched_window)
        self.settle()
        _, target = self.window()
        self.assertEqual(target, {"chatId": 42, "reply": False})
        self.assertIsNone(self.window()[1])   # handed over once

    def test_reply_summons_the_quick_reply_overlay(self):
        self.td_event(self.group([self.note(1, "hi")]))
        self.settle()
        self.click("reply")
        self.wait(lambda: self.spawned)
        argv, fallback = self.spawned[0]
        self.assertEqual(argv, [self.d.OMARCHY_SHELL, "shell", "summon", "reidenxerx.omagram", '{"chatId": 42}'])
        self.assertIsNone(self.daemon.pending_open)
        self.assertEqual(self.launched_window(), [])
        fallback()   # what a failed summon does: the window, composer focused
        _, target = self.window()
        self.assertEqual(target, {"chatId": 42, "reply": True})
        self.assertEqual(len(self.launched_window()), 1)

    def test_a_helper_that_fails_or_cannot_start_falls_back(self):
        del self.daemon.spawn   # the real one
        failed, missing, succeeded, hung = [], [], [], []
        self.daemon.spawn(["/usr/bin/false"], lambda: failed.append(True))
        self.daemon.spawn(["/nonexistent/omarchy-shell"], lambda: missing.append(True))
        self.daemon.spawn(["/usr/bin/true"], lambda: succeeded.append(True))
        self.daemon.spawn(["/usr/bin/sleep", "30"], lambda: hung.append(True), timeout=0.3)
        self.wait(lambda: failed and hung)
        self.wait(lambda: not self.daemon.children)
        self.assertEqual((failed, missing, succeeded, hung), ([True], [True], [], [True]))

    def test_a_closed_window_no_longer_hides_its_chat(self):
        window, _ = self.window()
        self.assertTrue(self.request(window, 80, "ui.focus", chatId=42)["ok"])
        self.conns.remove(window)
        window.sock.close()
        self.wait(lambda: self.daemon.focus_client is None)
        self.td_event(self.group([self.note(1, "hi")]))
        self.settle()
        self.assertEqual(len(self.bus.shown), 1)

    def test_an_open_window_hears_it_at_once(self):
        window, target = self.window()
        self.assertIsNone(target)
        self.td_event(self.group([self.note(1, "hi")]))
        self.settle()
        self.click("default")
        event = self.read(window, lambda v: v.get("event") == "open")
        self.assertEqual((event["chatId"], event["reply"]), (42, False))
        self.assertIsNone(self.window()[1])

    def test_ui_open_waits_only_for_a_window_and_not_forever(self):
        self.assertTrue(self.request(self.conn, 70, "ui.open", chatId=42)["ok"])
        self.assertIsNone(self.request(self.conn, 71, "hello")["result"]["open"])   # the bar is no window
        self.request(self.conn, 72, "ui.open", chatId=42)
        with mock.patch.object(self.d, "OPEN_TTL", 0.0):
            self.assertIsNone(self.window()[1])
        self.request(self.conn, 73, "ui.open", chatId=42)
        self.assertFalse(self.request(self.conn, 74, "ui.open", chatId="42")["ok"])


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
