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
        self.fake = FakeTd()
        self.keyring = FakeKeyring()
        self.daemon = self.d.Daemon(open_client=lambda: self.fake, keyring=self.keyring)
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
