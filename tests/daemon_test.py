#!/usr/bin/python3
"""python3 tests/daemon_test.py -- omagramd's socket service with a fake TDLib and keyring.

The real event loop runs in a thread on a real Unix socket inside a sandbox under
$XDG_RUNTIME_DIR; nothing talks to Telegram or the real keyring."""
import base64
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
import urllib.parse
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

    def execute(self, query):
        """TDLib's synchronous Markdown functions, for **bold** only."""
        value = query.get("text") or {}
        text = value.get("text", "")
        if query.get("@type") == "parseMarkdown":
            start = text.find("**")
            end = text.find("**", start + 2) if start >= 0 else -1
            if end < 0:
                return {"@type": "formattedText", "text": text, "entities": []}
            inner = text[start + 2:end]
            return {"@type": "formattedText", "text": text[:start] + inner + text[end + 2:],
                    "entities": [{"@type": "textEntity", "offset": start, "length": len(inner),
                                  "type": {"@type": "textEntityTypeBold"}}]}
        if query.get("@type") == "getMarkdownText":
            out = text
            for e in sorted(value.get("entities", []), key=lambda e: -e["offset"]):
                o, n = e["offset"], e["length"]
                out = out[:o] + "**" + out[o:o + n] + "**" + out[o + n:]
            return {"@type": "formattedText", "text": out, "entities": []}
        return None

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
                            ("LOCK", self.root / "omagram.lock"), ("CLOSE_TIMEOUT", 2.0), ("NOTIFY_IMAGES", self.root / "notify"),
                            ("SOUNDS", self.root / "sounds"), ("OMARCHY_NOTIFICATIONS", self.root / "omarchy-notifications.json")):
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

    # A command on self.conn, the TDLib query it makes and TDLib's answer to it.

    def sent_count(self, kind):
        return self.fake.sent_types().count(kind)

    def next_query(self, kind, before):
        self.wait(lambda: self.sent_count(kind) > before)
        return [q for q in self.fake.sent if q.get("@type") == kind][-1]

    def answer(self, query, result):
        self.td_event(dict(result, **{"@extra": query["@extra"], "@client_id": 1}))

    def call(self, rid, cmd, kind, result, **args):
        before = self.sent_count(kind)
        self.send(self.conn, {"id": rid, "cmd": cmd, "args": args})
        query = self.next_query(kind, before)
        self.answer(query, result)
        return query, self.read(self.conn, lambda v: v.get("id") == rid)


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

    def test_qr_sign_in_comes_with_a_picture_of_the_link(self):
        conn = self.connect()
        link = "tg://login?token=AQIDBAUGBwgJCgsMDQ4PEA"
        self.td_event(auth_update("authorizationStateWaitOtherDeviceConfirmation", link=link))
        auth = self.read(conn, lambda v: v.get("event") == "auth")["auth"]
        self.assertEqual((auth["state"], auth["link"]), ("qr", link))
        if not safe.has_tool("qrencode"):
            self.skipTest("qrencode is not installed")
        self.assertTrue(auth["image"].startswith("data:image/png;base64,"))
        if safe.has_tool("zbarimg"):
            png = self.root / "qr.png"
            png.write_bytes(base64.b64decode(auth["image"].split(",", 1)[1]))
            self.assertEqual(safe.run(["zbarimg", "--raw", "-q", str(png)], timeout=10).text().strip(), link)
        self.td_event(auth_update("authorizationStateWaitOtherDeviceConfirmation", link="https://example.com/not-a-login"))
        self.assertEqual(self.read(conn, lambda v: v.get("event") == "auth")["auth"].get("image", ""), "")

    def test_proxies_work_before_sign_in_and_keep_their_secrets(self):
        self.conn = self.connect()
        secret = "dd0123456789abcdef0123456789abcdef"
        mtproto = {"@type": "proxy", "server": "proxy.example.com", "port": 443, "type": {"@type": "proxyTypeMtproto", "secret": secret}}
        q, r = self.call(40, "proxy.add", "addProxy", {"@type": "addedProxy", "id": 1, "is_enabled": True, "last_used_date": 0, "proxy": mtproto},
                         type="mtproto", server="proxy.example.com", port=443, secret=secret)
        self.assertEqual((q["proxy"], q["enable"]), (mtproto, True))
        self.assertEqual(r["result"]["proxy"], {"id": 1, "server": "proxy.example.com", "port": 443, "type": "mtproto", "username": "",
                                                "enabled": True, "lastUsed": 0})
        self.assertNotIn(secret, json.dumps(r))
        q, _ = self.call(41, "proxy.add", "addProxy", {"@type": "addedProxy", "id": 2, "proxy": mtproto},
                         type="socks5", server="10.0.0.1", port=1080, username="ann", password="pw")
        self.assertEqual(q["proxy"]["type"], {"@type": "proxyTypeSocks5", "username": "ann", "password": "pw"})
        for rid, bad in enumerate(({"type": "socks5", "server": "bad host", "port": 1080}, {"type": "socks5", "server": "a", "port": 0},
                                   {"type": "mtproto", "server": "a", "port": 443, "secret": "short"}, {"type": "vpn", "server": "a", "port": 1}),
                                  start=42):
            self.assertFalse(self.request(self.conn, rid, "proxy.add", **bad)["ok"], bad)
        listed = {"@type": "addedProxies", "proxies": [{"@type": "addedProxy", "id": 1, "is_enabled": True, "proxy": mtproto}]}
        _, r = self.call(50, "proxies.list", "getProxies", listed)
        self.assertEqual(([p["id"] for p in r["result"]["proxies"]], r["result"]["connection"]), ([1], ""))
        self.assertNotIn(secret, json.dumps(r))
        q, _ = self.call(51, "proxy.enable", "enableProxy", {"@type": "ok"}, id=1)
        self.assertEqual(q["proxy_id"], 1)
        self.call(52, "proxy.disable", "disableProxy", {"@type": "ok"})
        q, _ = self.call(53, "proxy.remove", "removeProxy", {"@type": "ok"}, id=1)
        self.assertEqual(q["proxy_id"], 1)
        # A ping looks the proxy up first: the window never holds its secret.
        lists = self.sent_count("getProxies")
        self.send(self.conn, {"id": 54, "cmd": "proxy.ping", "args": {"id": 1}})
        self.answer(self.next_query("getProxies", lists), listed)
        ping = self.next_query("pingProxy", 0)
        self.assertEqual(ping["proxy"], mtproto)
        self.answer(ping, {"@type": "seconds", "seconds": 0.25})
        self.assertEqual(self.read(self.conn, lambda v: v.get("id") == 54)["result"], {"seconds": 0.25})
        # A proxy link: TDLib reads it, and the proxy it describes is added and used.
        reads, adds = self.sent_count("getInternalLinkType"), self.sent_count("addProxy")
        self.send(self.conn, {"id": 55, "cmd": "proxy.addLink", "args": {"link": "https://t.me/proxy?server=proxy.example.com&port=443&secret=" + secret}})
        self.answer(self.next_query("getInternalLinkType", reads), {"@type": "internalLinkTypeProxy", "proxy": mtproto})
        added = self.next_query("addProxy", adds)
        self.answer(added, {"@type": "addedProxy", "id": 3, "is_enabled": True, "proxy": mtproto})
        self.assertEqual((added["proxy"], added["enable"], self.read(self.conn, lambda v: v.get("id") == 55)["result"]["proxy"]["id"]),
                         (mtproto, True, 3))
        reads = self.sent_count("getInternalLinkType")
        self.send(self.conn, {"id": 56, "cmd": "proxy.addLink", "args": {"link": "https://t.me/durov"}})
        self.answer(self.next_query("getInternalLinkType", reads), {"@type": "internalLinkTypePublicChat", "chat_username": "durov"})
        self.assertEqual(self.read(self.conn, lambda v: v.get("id") == 56)["error"], "That is not a proxy link")

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

        # A caption is edited on its own, and may be emptied.
        self.send(conn, {"id": 39, "cmd": "message.edit", "args": {"chatId": 42, "messageId": 9, "text": "", "caption": True}})
        query = self.last_query("editMessageCaption")
        self.assertEqual((query["message_id"], query["caption"]["text"]), (9, ""))
        self.assertFalse(self.request(conn, 40, "message.edit", chatId=42, messageId=9, text="x" * 1025, caption=True)["ok"])
        self.assertFalse(self.request(conn, 41, "message.edit", chatId=42, messageId=9, text="")["ok"], "a text message needs text")

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

    def test_listening_fetches_the_message_plays_its_sound_and_stops(self):
        class FakePlayer:
            pid = 2 ** 22 + 123   # no such process: signalling it does nothing
            code = None

            def poll(self):
                return self.code

            def wait(self, timeout=None):
                return 0

            def kill(self):
                self.code = -9
        players = []

        def start_helper(argv):
            players.append((argv, FakePlayer()))
            return players[-1][1]
        self.daemon.start_helper = start_helper
        self.daemon.prefs = dict(self.daemon.prefs, playbackRate=1.5)
        voice = self.files / "voice" / "v.ogg"
        voice.parent.mkdir(mode=0o700)
        voice.write_bytes(b"OggS")
        self.send(self.conn, {"id": 90, "cmd": "media.play", "args": {"chatId": 42, "messageId": 7, "fileId": 9}})
        query = self.last_query("downloadFile")
        self.assertEqual((query["file_id"], query["synchronous"], query["priority"]), (9, True, 32), "fetched first, at once")
        self.td_event(self.file_event(query["@extra"], 9, voice))
        # Everyone hears it is playing, then the one who asked gets the answer: read in that order.
        self.assertEqual(self.read(self.conn, lambda v: v.get("event") == "playing")["fileId"], 9)
        self.assertTrue(self.read(self.conn, lambda v: v.get("id") == 90)["ok"])
        argv = players[0][0]
        self.assertEqual((argv[0].endswith("/ffplay"), "-nodisp" in argv, argv[-3:]), (True, True, ["-af", "atempo=1.5", str(voice)]))
        self.assertEqual(self.last_query("openMessageContent")["message_id"], 7, "it counts as listened to")
        self.send(self.conn, {"id": 91, "cmd": "media.stop", "args": {}})
        self.read(self.conn, lambda v: v.get("event") == "playing" and v.get("fileId") == 0)
        self.assertTrue(self.read(self.conn, lambda v: v.get("id") == 91)["ok"])
        before = self.sent_count("downloadFile")
        self.send(self.conn, {"id": 92, "cmd": "media.play", "args": {"chatId": 42, "messageId": 8, "fileId": 9}})
        self.td_event(self.file_event(self.next_query("downloadFile", before)["@extra"], 9, voice))
        self.read(self.conn, lambda v: v.get("event") == "playing" and v.get("fileId") == 9)
        players[-1][1].code = 0   # it comes to its end by itself
        self.daemon.wake()
        self.read(self.conn, lambda v: v.get("event") == "playing" and v.get("fileId") == 0)
        before = self.sent_count("downloadFile")
        self.send(self.conn, {"id": 93, "cmd": "media.play", "args": {"chatId": 42, "messageId": 8, "fileId": 9}})
        self.td_event(self.file_event(self.next_query("downloadFile", before)["@extra"], 9, self.root / "elsewhere.ogg"))
        self.assertFalse(self.read(self.conn, lambda v: v.get("id") == 93)["ok"], "only files in TDLib's media folders")

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

    def test_a_failed_sticker_is_not_inflated_again(self):
        import gzip
        bad = self.files / "stickers" / "bad.tgs"
        bad.write_bytes(gzip.compress(b"[1, 2, 3]"))
        inflaters = []
        real = self.d.zlib.decompressobj
        with mock.patch.object(self.d.zlib, "decompressobj", lambda *args: inflaters.append(1) or real(*args)):
            self.assertEqual(self.lottie(80, bad)["result"]["path"], "")
            self.assertEqual(self.lottie(81, bad)["result"]["path"], "")
        self.assertEqual(len(inflaters), 1, "the second request is answered from memory")

    def test_the_sticker_cache_stays_under_its_ceiling_oldest_first(self):
        cache = self.root / "lottie"
        cache.mkdir(mode=0o700, exist_ok=True)
        for n in range(6):
            unpacked = cache / f"{n:064x}.json"
            unpacked.write_bytes(b"{}" * 50)
            os.utime(unpacked, (1000 + n, 1000 + n))
        with mock.patch.object(self.d, "LOTTIE_CACHE_FILES", 5):
            self.d.trim_lottie_cache()
        self.assertEqual(sorted(int(p.stem, 16) for p in cache.iterdir()), [2, 3, 4, 5])

    def test_a_round_video_moves_in_the_quick_view_as_a_kept_picture(self):
        note = self.files / "video_notes" / "n.mp4"
        note.parent.mkdir(mode=0o700)
        note.write_bytes(b"mp4")
        made = []

        def make(source):
            made.append(source)
            target = self.root / "notes" / "made.webp"
            target.parent.mkdir(mode=0o700, exist_ok=True)
            target.write_bytes(b"RIFF")
            return target
        for patch in (mock.patch.object(self.d.media, "NOTE_ANIMATIONS", self.root / "notes"),
                      mock.patch.object(self.d.media, "make_note_animation", make),
                      mock.patch.object(self.d.safe, "has_tool", lambda name: True)):
            patch.start()
            self.addCleanup(patch.stop)

        def ask(rid, path):
            before = self.sent_count("downloadFile")
            self.send(self.conn, {"id": rid, "cmd": "videonote.animation", "args": {"fileId": 11}})
            query = self.next_query("downloadFile", before)
            self.assertEqual((query["file_id"], query["priority"], query["synchronous"]), (11, 32, True), "fetched at once")
            self.td_event(self.file_event(query["@extra"], 11, path))
            return self.read(self.conn, lambda v: v.get("id") == rid)

        answer = ask(95, note)
        self.assertEqual(answer["result"], {"path": str(self.root / "notes" / "made.webp"), "fps": self.d.media.NOTE_ANIMATION_RATE})
        self.assertEqual(made, [str(note)])
        kept = self.d.media.note_animation_path(str(note))
        kept.write_bytes(b"RIFF")
        self.assertEqual(ask(96, note)["result"]["path"], str(kept), "a kept picture is answered at once")
        self.assertEqual(len(made), 1)
        self.assertFalse(ask(97, self.root / "elsewhere.mp4")["ok"], "only files in TDLib's media folders")
        kept.unlink()

        def broken(source):
            raise self.d.safe.UnsafeError("not a video")
        with mock.patch.object(self.d.media, "make_note_animation", broken):
            self.assertFalse(ask(98, note)["ok"], "a failure is an answer, not silence")

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
        self.td_event({"@type": "stickerSet", "@extra": q["@extra"], "@client_id": 1, "title": "Pandas", "is_installed": True,
                       "stickers": [self.sticker(8)]})
        one = self.read(self.conn, lambda v: v.get("id") == 52)["result"]
        self.assertEqual((one["title"], [s["file"]["id"] for s in one["stickers"]], one["installed"]), ("Pandas", [8], True))
        for bad in (123, "12a", ""):
            self.assertFalse(self.request(self.conn, 53, "stickers.set", setId=bad)["ok"], bad)

        _, r = self.call(54, "stickers.favorites", "getFavoriteStickers", {"@type": "stickers", "stickers": [self.sticker(9)]})
        self.assertEqual([s["file"]["id"] for s in r["result"]["stickers"]], [9])
        q, _ = self.call(55, "sticker.favorite", "addFavoriteSticker", {"@type": "ok"}, fileId=9, favorite=True)
        self.assertEqual(q["sticker"], {"@type": "inputFileId", "id": 9})
        q, _ = self.call(56, "sticker.favorite", "removeFavoriteSticker", {"@type": "ok"}, fileId=9, favorite=False)
        self.assertEqual(q["sticker"]["id"], 9)
        self.assertFalse(self.request(self.conn, 57, "sticker.favorite", fileId=9, favorite="yes")["ok"])
        q, _ = self.call(58, "stickers.install", "changeStickerSet", {"@type": "ok"}, setId="9223372036854775807", installed=True)
        self.assertEqual((q["set_id"], q["is_installed"], q["is_archived"]), (9223372036854775807, True, False))
        self.assertFalse(self.request(self.conn, 59, "stickers.install", setId="x", installed=True)["ok"])


    def test_link_previews_while_typing_and_where_they_go(self):
        q, r = self.call(80, "message.linkPreview", "getLinkPreview", {
            "@type": "linkPreview", "url": "https://example.com/a", "display_url": "example.com/a", "site_name": "Example", "title": "A page",
            "description": {"@type": "formattedText", "text": "About it", "entities": []}, "type": {"@type": "linkPreviewTypeUnsupported"},
            "show_above_text": False}, chatId=42, text="look **at** example.com/a")
        self.assertEqual((q["text"]["text"], q["link_preview_options"]), ("look at example.com/a", None))
        preview = r["result"]["preview"]
        self.assertEqual((preview["siteName"], preview["title"], preview["description"], preview["above"]), ("Example", "A page", "About it", False))
        for rid, where, options in ((81, "below", None), (82, "above", (False, True)), (83, "none", (True, False))):
            q, _ = self.call(rid, "message.send", "sendMessage", {"@type": "message", "id": rid, "chat_id": 42}, chatId=42,
                             text="look example.com/a", linkPreview=where)
            got = q["input_message_content"]["link_preview_options"]
            self.assertEqual(got and (got["is_disabled"], got["show_above_text"]), options, where)
        self.assertFalse(self.request(self.conn, 84, "message.send", chatId=42, text="hi", linkPreview="left")["ok"])

    def test_markdown_is_read_into_formatting_and_written_back_for_editing(self):
        bold = {"@type": "textEntity", "offset": 3, "length": 5, "type": {"@type": "textEntityTypeBold"}}
        q, r = self.call(90, "message.send", "sendMessage", {"@type": "message", "id": 10, "chat_id": 42}, chatId=42, text="hi **there**")
        self.assertEqual((q["input_message_content"]["text"], r["ok"]),
                         ({"@type": "formattedText", "text": "hi there", "entities": [bold]}, True))
        q, _ = self.call(91, "message.send", "sendMessage", {"@type": "message", "id": 11, "chat_id": 42}, chatId=42,
                         text="**" + "x" * 4096 + "**")
        self.assertEqual(len(q["input_message_content"]["text"]["text"]), 4096, "markers do not count towards the limit")
        self.assertFalse(self.request(self.conn, 92, "message.send", chatId=42, text="**" + "x" * 4097 + "**")["ok"])
        q, _ = self.call(93, "message.edit", "editMessageText", {"@type": "message", "id": 10, "chat_id": 42},
                         chatId=42, messageId=10, text="hi **there**")
        self.assertEqual(q["input_message_content"]["text"]["entities"], [bold])
        q, _ = self.call(94, "message.edit", "editMessageCaption", {"@type": "message", "id": 12, "chat_id": 42},
                         chatId=42, messageId=12, text="hi **there**", caption=True)
        self.assertEqual(q["caption"]["entities"], [bold])
        photo = self.file("cat.png", 1000)
        q, _ = self.call(95, "message.sendFile", "sendMessage", {"@type": "message", "id": 13, "chat_id": 42},
                         chatId=42, path=str(photo), caption="hi **there**")
        self.assertEqual(q["input_message_content"]["caption"]["entities"], [bold])
        text = {"@type": "formattedText", "text": "hi there", "entities": [bold]}
        q, r = self.call(96, "message.markdown", "getMessage", {"@type": "message", "id": 10, "chat_id": 42,
                                                               "content": {"@type": "messageText", "text": text}},
                         chatId=42, messageId=10)
        self.assertEqual((q["message_id"], r["result"]["text"]), (10, "hi **there**"))
        _, r = self.call(97, "message.markdown", "getMessage", {"@type": "message", "id": 12, "chat_id": 42,
                                                               "content": {"@type": "messagePhoto", "caption": text}},
                         chatId=42, messageId=12)
        self.assertEqual(r["result"]["text"], "hi **there**", "a caption too")
        link = {"@type": "textEntity", "offset": 0, "length": 3, "type": {"@type": "textEntityTypeTextUrl", "url": "tg://user?id=202"}}
        web = dict(link, type={"@type": "textEntityTypeTextUrl", "url": "https://tg.example/user?id=202"})
        self.assertEqual(self.d.mention_links([link, web, "junk"]),
                         [dict(link, type={"@type": "textEntityTypeMentionName", "user_id": 202}), web, "junk"],
                         "a Markdown link to tg://user?id= is a mention by name")


    def test_files_go_as_albums_videos_and_music_with_the_caption_on_the_first(self):
        d = self.d
        self.assertEqual(d.album_groups(["photo", "video", "document", "photo", "audio", "document"]), [[0, 1, 3], [2, 5], [4]])
        self.assertEqual(d.album_groups(["photo"] * 12), [list(range(10)), [10, 11]])
        cats = [str(self.file(f"cat{i}.jpg", 1000)) for i in range(3)]
        album = {"@type": "messages", "total_count": 3, "messages": []}
        q, r = self.call(100, "message.sendFiles", "sendMessageAlbum", album, chatId=42, paths=cats, caption="**all**", replyToMessageId=9)
        contents = q["input_message_contents"]
        self.assertEqual([c["@type"] for c in contents], ["inputMessagePhoto"] * 3)
        self.assertEqual((contents[0]["caption"]["text"], contents[0]["caption"]["entities"][0]["type"]["@type"], contents[1]["caption"]),
                         ("all", "textEntityTypeBold", None))
        self.assertEqual((q["reply_to"]["message_id"], r["result"]), (9, {"groups": 1}))

        clip, pdf = str(self.file("clip.mp4", 5000)), str(self.file("report.pdf"))
        with mock.patch.object(d.media, "probe_media", return_value=(12, 1280, 720)):
            albums, singles = self.sent_count("sendMessageAlbum"), self.sent_count("sendMessage")
            self.send(self.conn, {"id": 101, "cmd": "message.sendFiles",
                                  "args": {"chatId": 42, "paths": [cats[0], pdf, clip], "caption": "mixed", "replyToMessageId": 9}})
            media_album = self.next_query("sendMessageAlbum", albums)
            document = self.next_query("sendMessage", singles)
        self.answer(media_album, album)
        self.answer(document, {"@type": "message", "id": 3, "chat_id": 42})
        r = self.read(self.conn, lambda v: v.get("id") == 101)
        video = media_album["input_message_contents"][1]["video"]
        self.assertEqual([c["@type"] for c in media_album["input_message_contents"]], ["inputMessagePhoto", "inputMessageVideo"],
                         "photos and videos share an album; the file goes on its own")
        self.assertEqual((video["duration"], video["width"], video["height"], video["supports_streaming"]), (12, 1280, 720, True))
        self.assertEqual((media_album["reply_to"]["message_id"], document["reply_to"], document["input_message_content"]["@type"],
                          document["input_message_content"]["caption"]), (9, None, "inputMessageDocument", None))
        self.assertEqual(r["result"], {"groups": 2})

        q, _ = self.call(102, "message.sendFiles", "sendMessageAlbum", album, chatId=42, paths=cats[:2], asMedia=False)
        self.assertEqual([c["@type"] for c in q["input_message_contents"]], ["inputMessageDocument"] * 2, "as files")
        song = str(self.file("song.mp3", 3000))
        with mock.patch.object(d.media, "probe_media", return_value=(200, 0, 0)):
            q, _ = self.call(103, "message.sendFile", "sendMessage", {"@type": "message", "id": 4, "chat_id": 42}, chatId=42, path=song)
        self.assertEqual((q["input_message_content"]["@type"], q["input_message_content"]["audio"]["duration"]), ("inputMessageAudio", 200))
        for rid, bad in enumerate(({"paths": cats * 4}, {"paths": cats, "asMedia": "yes"},
                                   {"paths": [cats[0], str(self.uploads / "gone.jpg")]}, {"paths": []}), start=104):
            self.assertFalse(self.request(self.conn, rid, "message.sendFiles", chatId=42, **bad)["ok"], bad)


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


class MessageActions(Harness):
    def setUp(self):
        super().setUp()
        self.conn = self.connect()
        self.sign_in(self.conn)
        self.td_event({"@type": "updateNewChat", "@client_id": 1, "chat": {
            "@type": "chat", "id": 42, "title": "Friends", "type": {"@type": "chatTypeBasicGroup"},
            "notification_settings": {"@type": "chatNotificationSettings", "use_default_mute_for": True, "mute_for": 0,
                                      "show_preview": True, "sound_id": "5"},
            "positions": [{"@type": "chatPosition", "list": {"@type": "chatListMain"}, "order": "7"}]}})
        self.td_event({"@type": "updateNewChat", "@client_id": 1, "chat": {
            "@type": "chat", "id": 500, "title": "Helper bot", "type": {"@type": "chatTypePrivate", "user_id": 500}}})
        self.read(self.conn, lambda v: v.get("event") == "chat" and v["chat"]["id"] == 500)

    def test_forward_properties_link_pin_reactions(self):
        q, r = self.call(1, "message.forward", "forwardMessages", {"@type": "messages", "messages": [{}, {}]},
                         chatId=42, fromChatId=500, messageIds=[7, 8])
        self.assertEqual((q["chat_id"], q["from_chat_id"], q["message_ids"], q["send_copy"], r["result"]["count"]),
                         (42, 500, [7, 8], False, 2))
        q, r = self.call(2, "message.properties", "getMessageProperties",
                         {"@type": "messageProperties", "can_be_deleted_for_all_users": True, "can_be_edited": False,
                          "can_be_forwarded": True, "can_be_pinned": True}, chatId=42, messageId=7)
        self.assertEqual(r["result"], {"canDeleteForAll": True, "canDeleteForMe": False, "canEdit": False, "canForward": True,
                                       "canPin": True, "canCopy": False, "canReply": False, "canGetLink": False, "canSave": False,
                                       "canGetThread": False, "canGetViewers": False})
        q, r = self.call(3, "message.link", "getMessageLink", {"@type": "messageLink", "link": "https://t.me/x/7", "is_public": True},
                         chatId=42, messageId=7)
        self.assertEqual(r["result"], {"link": "https://t.me/x/7", "public": True})
        q, _ = self.call(4, "message.pin", "pinChatMessage", {"@type": "ok"}, chatId=42, messageId=7, pinned=True)
        self.assertEqual((q["disable_notification"], q["only_for_self"]), (True, False))
        q, _ = self.call(5, "message.pin", "unpinChatMessage", {"@type": "ok"}, chatId=42, messageId=7, pinned=False)
        self.assertEqual(q["message_id"], 7)
        self.assertFalse(self.request(self.conn, 6, "message.pin", chatId=42, messageId=7)["ok"])
        q, r = self.call(7, "chat.pinned", "getChatPinnedMessage", {"@type": "message", "id": 7, "chat_id": 42, "date": 1,
                                                                    "content": {"@type": "messageText", "text": {"text": "rules"}}},
                         chatId=42)
        self.assertEqual(r["result"]["message"]["content"]["text"], "rules")
        q, _ = self.call(8, "reaction.set", "addMessageReaction", {"@type": "ok"}, chatId=42, messageId=7, emoji="👍", chosen=True)
        self.assertEqual((q["reaction_type"], q["is_big"]), ({"@type": "reactionTypeEmoji", "emoji": "👍"}, False))
        self.call(9, "reaction.set", "removeMessageReaction", {"@type": "ok"}, chatId=42, messageId=7, emoji="👍", chosen=False)
        _, r = self.call(10, "reactions.available", "getMessageAvailableReactions", {
            "@type": "availableReactions",
            "top_reactions": [{"@type": "availableReaction", "type": {"@type": "reactionTypeEmoji", "emoji": "👍"}},
                              {"@type": "availableReaction", "type": {"@type": "reactionTypeEmoji", "emoji": "🦄"}, "needs_premium": True}],
            "recent_reactions": [{"@type": "availableReaction", "type": {"@type": "reactionTypeEmoji", "emoji": "👍"}},
                                 {"@type": "availableReaction", "type": {"@type": "reactionTypeCustomEmoji", "custom_emoji_id": "1"}},
                                 {"@type": "availableReaction", "type": {"@type": "reactionTypeEmoji", "emoji": "🔥"}}]},
            chatId=42, messageId=7)
        self.assertEqual(r["result"]["emoji"], ["👍", "🔥"])

    def test_buttons_polls_actions_drafts_mute_mentions(self):
        q, r = self.call(20, "button.callback", "getCallbackQueryAnswer",
                         {"@type": "callbackQueryAnswer", "text": "Done", "show_alert": True, "url": ""}, chatId=500, messageId=3, data="eWVz")
        self.assertEqual((q["payload"], r["result"]), ({"@type": "callbackQueryPayloadData", "data": "eWVz"},
                                                       {"text": "Done", "alert": True, "url": ""}))
        for rid, bad in enumerate(("", "not base64!", "A" * 200, 5), start=21):
            self.assertFalse(self.request(self.conn, rid, "button.callback", chatId=500, messageId=3, data=bad)["ok"], bad)
        q, _ = self.call(30, "poll.vote", "setPollAnswer", {"@type": "ok"}, chatId=42, messageId=9, optionIds=[1])
        self.assertEqual(q["option_ids"], [1])
        self.call(31, "poll.vote", "setPollAnswer", {"@type": "ok"}, chatId=42, messageId=9, optionIds=[])
        for rid, bad in enumerate(([12], [-1], ["1"], [True], "1"), start=32):
            self.assertFalse(self.request(self.conn, rid, "poll.vote", chatId=42, messageId=9, optionIds=bad)["ok"], bad)
        q, _ = self.call(40, "chat.action", "sendChatAction", {"@type": "ok"}, chatId=42, action="typing")
        self.assertEqual((q["action"], q["business_connection_id"]), ({"@type": "chatActionTyping"}, ""))
        self.assertFalse(self.request(self.conn, 41, "chat.action", chatId=42, action="dancing")["ok"])
        q, _ = self.call(42, "chat.draft", "setChatDraftMessage", {"@type": "ok"}, chatId=42, text="half", replyToMessageId=9)
        self.assertEqual((q["draft_message"]["content"]["text"]["text"], q["draft_message"]["reply_to"]["message_id"]), ("half", 9))
        q, _ = self.call(43, "chat.draft", "setChatDraftMessage", {"@type": "ok"}, chatId=42, text="  ")
        self.assertIsNone(q["draft_message"])
        q, _ = self.call(44, "chat.mute", "setChatNotificationSettings", {"@type": "ok"}, chatId=42, muteFor=2 ** 31 - 1)
        settings = q["notification_settings"]
        self.assertEqual((settings["use_default_mute_for"], settings["mute_for"], settings["show_preview"], settings["sound_id"]),
                         (False, 2 ** 31 - 1, True, "5"), "only the mute changes")
        q, _ = self.call(45, "chat.mute", "setChatNotificationSettings", {"@type": "ok"}, chatId=42, muteFor=-1)
        self.assertEqual((q["notification_settings"]["use_default_mute_for"], q["notification_settings"]["mute_for"]), (True, 0))
        self.assertFalse(self.request(self.conn, 46, "chat.mute", chatId=999, muteFor=0)["ok"])
        q, r = self.call(47, "chat.nextMention", "searchChatMessages",
                         {"@type": "foundChatMessages", "messages": [{"@type": "message", "id": 90}, {"@type": "message", "id": 70}]},
                         chatId=42)
        self.assertEqual((q["filter"], r["result"]["messageId"]), ({"@type": "searchMessagesFilterUnreadMention"}, 70))
        self.call(48, "chat.readMentions", "readAllChatMentions", {"@type": "ok"}, chatId=42)

    def test_links_lead_inside_telegram_or_to_the_web(self):
        self.assertEqual(self.request(self.conn, 50, "link.open", url="https://example.com/a")["result"],
                         {"kind": "external", "url": "https://example.com/a"})
        for rid, bad in enumerate(("javascript:alert(1)", "file:///etc/passwd", "", 5), start=51):
            self.assertFalse(self.request(self.conn, rid, "link.open", url=bad)["ok"], bad)
        # a username
        before = self.sent_count("getInternalLinkType")
        self.send(self.conn, {"id": 60, "cmd": "link.open", "args": {"url": "https://t.me/durov"}})
        q = self.next_query("getInternalLinkType", before)
        before = self.sent_count("searchPublicChat")
        self.answer(q, {"@type": "internalLinkTypePublicChat", "chat_username": "durov"})
        q = self.next_query("searchPublicChat", before)
        self.assertEqual(q["username"], "durov")
        self.answer(q, {"@type": "chat", "id": 777})
        self.assertEqual(self.read(self.conn, lambda v: v.get("id") == 60)["result"], {"kind": "chat", "chatId": 777})
        # a message link
        before = self.sent_count("getInternalLinkType")
        self.send(self.conn, {"id": 61, "cmd": "link.open", "args": {"url": "https://t.me/c/1/5"}})
        q = self.next_query("getInternalLinkType", before)
        before = self.sent_count("getMessageLinkInfo")
        self.answer(q, {"@type": "internalLinkTypeMessage", "url": "tg://privatepost?channel=1&post=5"})
        q = self.next_query("getMessageLinkInfo", before)
        self.answer(q, {"@type": "messageLinkInfo", "chat_id": -100, "message": {"@type": "message", "id": 5}})
        self.assertEqual(self.read(self.conn, lambda v: v.get("id") == 61)["result"], {"kind": "chat", "chatId": -100, "messageId": 5})
        # an invite
        before = self.sent_count("getInternalLinkType")
        self.send(self.conn, {"id": 62, "cmd": "link.open", "args": {"url": "https://t.me/+abc"}})
        q = self.next_query("getInternalLinkType", before)
        before = self.sent_count("checkChatInviteLink")
        self.answer(q, {"@type": "internalLinkTypeChatInvite", "invite_link": "https://t.me/+abc"})
        q = self.next_query("checkChatInviteLink", before)
        self.answer(q, {"@type": "chatInviteLinkInfo", "title": "Club", "member_count": 12, "chat_id": 0})
        self.assertEqual(self.read(self.conn, lambda v: v.get("id") == 62)["result"],
                         {"kind": "invite", "link": "https://t.me/+abc", "title": "Club", "members": 12, "chatId": 0})
        # a proxy link: the window asks before it is used
        before = self.sent_count("getInternalLinkType")
        link = "https://t.me/proxy?server=p.example.com&port=443&secret=dd00aa"
        self.send(self.conn, {"id": 169, "cmd": "link.open", "args": {"url": link}})
        q = self.next_query("getInternalLinkType", before)
        self.answer(q, {"@type": "internalLinkTypeProxy", "proxy": {"@type": "proxy", "server": "p.example.com", "port": 443,
                                                                    "type": {"@type": "proxyTypeMtproto", "secret": "dd00aa"}}})
        self.assertEqual(self.read(self.conn, lambda v: v.get("id") == 169)["result"],
                         {"kind": "proxy", "link": link, "server": "p.example.com", "port": 443, "type": "mtproto"})
        # TDLib does not recognise it: it is a web page after all
        before = self.sent_count("getInternalLinkType")
        self.send(self.conn, {"id": 63, "cmd": "link.open", "args": {"url": "https://t.me/"}})
        q = self.next_query("getInternalLinkType", before)
        self.td_event({"@type": "error", "code": 400, "message": "Link is not recognized", "@extra": q["@extra"], "@client_id": 1})
        self.assertEqual(self.read(self.conn, lambda v: v.get("id") == 63)["result"]["kind"], "external")
        q, r = self.call(64, "chat.joinLink", "joinChatByInviteLink", {"@type": "chatJoinResultSuccess", "chat_id": 888},
                         link="https://t.me/+abc")
        self.assertEqual(r["result"], {"chatId": 888, "state": "joined"})
        q, _ = self.call(65, "bot.start", "sendBotStartMessage", {"@type": "message", "id": 1, "chat_id": 500},
                         chatId=500, parameter="ref42")
        self.assertEqual((q["bot_user_id"], q["parameter"]), (500, "ref42"))
        self.assertFalse(self.request(self.conn, 66, "bot.start", chatId=42, parameter="x")["ok"], "not a private chat")
        q, r = self.call(67, "user.chat", "createPrivateChat", {"@type": "chat", "id": 8}, userId=8)
        self.assertEqual(r["result"], {"chatId": 8})
        q, r = self.call(68, "username.chat", "searchPublicChat", {"@type": "chat", "id": 9}, username="@some_bot")
        self.assertEqual((q["username"], r["result"]), ("some_bot", {"chatId": 9}))
        self.assertFalse(self.request(self.conn, 69, "username.chat", username="a b")["ok"])

    def test_files_open_save_and_clipboard_images(self):
        files = self.root / "files"
        files.mkdir(mode=0o700)
        document = files / "report.pdf"
        document.write_bytes(b"%PDF-1.7 data")
        downloads = self.root / "Downloads"
        spawned = []
        for target, value in ((self.d.td, ("MEDIA_ROOTS", (str(files),))), (self.d, ("DOWNLOADS", downloads))):
            patch = mock.patch.object(target, value[0], value[1])
            patch.start()
            self.addCleanup(patch.stop)
        self.daemon.spawn = lambda argv, fallback=None, timeout=None: spawned.append(argv)
        done = {"@type": "file", "id": 5, "local": {"path": str(document), "is_downloading_completed": True}}
        q, r = self.call(70, "file.open", "getFile", done, fileId=5)
        self.assertEqual((r["ok"], spawned), (True, [["/usr/bin/xdg-open", str(document)]]))
        _, r = self.call(71, "file.open", "getFile", {"@type": "file", "id": 5, "local": {"path": str(document)}}, fileId=5)
        self.assertFalse(r["ok"], "not downloaded yet")
        _, r = self.call(72, "file.open", "getFile", dict(done, local={"path": "/etc/passwd", "is_downloading_completed": True}), fileId=5)
        self.assertFalse(r["ok"], "outside Omagram's files")
        _, first = self.call(73, "file.save", "getFile", done, fileId=5, fileName="../../Report.pdf")
        _, second = self.call(74, "file.save", "getFile", done, fileId=5, fileName="../../Report.pdf")
        self.assertEqual((first["result"]["path"], second["result"]["path"]),
                         (str(downloads / "Report.pdf"), str(downloads / "Report (2).pdf")))
        self.assertEqual((downloads / "Report (2).pdf").read_bytes(), b"%PDF-1.7 data")
        with mock.patch.object(self.d, "clipboard_types", lambda: ["text/plain", "image/png"]), \
             mock.patch.object(self.d, "clipboard_data", lambda mime: b"\x89PNG image"):
            path = self.request(self.conn, 75, "clipboard.image")["result"]["path"]
        self.assertEqual((os.path.dirname(path), pathlib.Path(path).read_bytes(), os.stat(path).st_mode & 0o777),
                         (str(self.d.media.REC), b"\x89PNG image", 0o600))
        with mock.patch.object(self.d, "clipboard_types", lambda: ["text/plain"]):
            self.assertEqual(self.request(self.conn, 76, "clipboard.image")["result"], {"path": ""})

    def test_pasting_copied_files_or_a_picture(self):
        picked = self.root / "picked"
        picked.mkdir(mode=0o700)
        photo = picked / "cat photo.jpg"
        photo.write_bytes(b"jpeg data")
        report = picked / "report.pdf"
        report.write_bytes(b"%PDF-1.7")
        folder = picked / "folder"
        folder.mkdir()
        empty = picked / "empty.txt"
        empty.write_bytes(b"")

        def address(path, host=""):
            return "file://" + host + urllib.parse.quote(str(path))

        def paste(rid, offered):
            with mock.patch.object(self.d, "clipboard_types", lambda: list(offered)), \
                    mock.patch.object(self.d, "clipboard_data", lambda mime: offered.get(mime)):
                return self.request(self.conn, rid, "clipboard.files")["result"]

        listing = "\r\n".join(["# copied in a file manager", address(photo), address(report, "localhost"), address(folder),
                               address(empty), "https://example.org/cat.png", "file://elsewhere/etc/hosts", address(photo)])
        self.assertEqual(paste(80, {"text/uri-list": listing.encode(), "text/plain": b"cat photo.jpg", "image/png": b"PNG"}),
                         {"paths": [str(photo), str(report)], "skipped": 2},
                         "copied files come before a picture; a folder and an empty file are left out and said")
        picture = paste(81, {"image/png": b"PNG bytes"})
        self.assertEqual((picture["skipped"], len(picture["paths"])), (0, 1))
        self.assertEqual((os.path.dirname(picture["paths"][0]), pathlib.Path(picture["paths"][0]).read_bytes()),
                         (str(self.d.media.REC), b"PNG bytes"))
        self.assertEqual(paste(82, {"text/uri-list": b"https://example.org/", "text/plain": b"https://example.org/"}),
                         {"paths": [], "skipped": 0}, "a copied link is text to paste")
        self.assertEqual(paste(83, {"text/plain": b"hello"}), {"paths": [], "skipped": 0})
        many = []
        for n in range(12):
            extra = picked / f"note-{n}.txt"
            extra.write_bytes(b"x")
            many.append(address(extra))
        self.assertEqual(len(paste(84, {"text/uri-list": "\n".join(many).encode()})["paths"]), 10, "ten at most, as an album holds")
        self.assertEqual(paste(85, {"text/uri-list": address(folder).encode()}), {"paths": [], "skipped": 1},
                         "only a folder: that is said, not pasted as text")


class ChatsAndAccount(Harness):
    def setUp(self):
        super().setUp()
        self.conn = self.connect()
        self.sign_in(self.conn)
        main = [{"@type": "chatPosition", "list": {"@type": "chatListMain"}, "order": "5"}]
        for update in (
            {"@type": "updateUser", "user": {"@type": "user", "id": 500, "first_name": "Ann", "phone_number": "380671234567",
                                              "usernames": {"@type": "usernames", "active_usernames": ["ann"]}}},
            {"@type": "updateUser", "user": {"@type": "user", "id": 501, "first_name": "Bob"}},
            {"@type": "updateSupergroup", "supergroup": {"@type": "supergroup", "id": 77, "member_count": 1234, "is_forum": True,
                                                         "usernames": {"@type": "usernames", "active_usernames": ["club"]},
                                                         "status": {"@type": "chatMemberStatusMember"}}},
            {"@type": "updateBasicGroup", "basic_group": {"@type": "basicGroup", "id": 66, "member_count": 3,
                                                          "status": {"@type": "chatMemberStatusCreator"}}},
            {"@type": "updateNewChat", "chat": {"@type": "chat", "id": 500, "title": "Ann", "positions": main,
                                                "type": {"@type": "chatTypePrivate", "user_id": 500}}},
            {"@type": "updateNewChat", "chat": {"@type": "chat", "id": -66, "title": "Friends", "positions": main,
                                                "type": {"@type": "chatTypeBasicGroup", "basic_group_id": 66}}},
            {"@type": "updateNewChat", "chat": {"@type": "chat", "id": -10077, "title": "Club", "positions": main,
                                                "type": {"@type": "chatTypeSupergroup", "supergroup_id": 77, "is_channel": False}}},
        ):
            self.td_event(dict(update, **{"@client_id": 1}))
        self.read(self.conn, lambda v: v.get("event") == "chat" and v["chat"]["id"] == -10077)

    def test_chat_views_know_group_sizes_usernames_forums_and_your_place(self):
        chats = {c["id"]: c for c in self.request(self.conn, 1, "chats.list", list="main")["result"]["chats"]}
        club = chats[-10077]
        self.assertEqual((club["memberCount"], club["username"], club["forum"], club["myStatus"]), (1234, "club", True, "member"))
        self.assertEqual((chats[-66]["memberCount"], chats[-66]["myStatus"]), (3, "owner"))
        self.assertEqual((chats[500]["username"], chats[500]["forum"]), ("ann", False))
        self.assertNotIn("380671234567", json.dumps(chats), "phone numbers stay out of chat lists")

    def test_info_for_a_person_a_group_and_a_supergroup(self):
        q, r = self.call(10, "chat.info", "getUserFullInfo", {"@type": "userFullInfo", "group_in_common_count": 2,
                                                              "bio": {"@type": "formattedText", "text": "hi there", "entities": []}},
                         chatId=500)
        info = r["result"]
        self.assertEqual((q["user_id"], info["username"], info["phone"], info["bio"]["text"], info["commonGroups"]),
                         (500, "ann", "380671234567", "hi there", 2))
        member = lambda uid, status: {"@type": "chatMember", "member_id": {"@type": "messageSenderUser", "user_id": uid},
                                      "status": {"@type": status}}
        q, r = self.call(11, "chat.info", "getBasicGroupFullInfo", {
            "@type": "basicGroupFullInfo", "description": "our group", "members": [
                member(500, "chatMemberStatusCreator"), member(501, "chatMemberStatusMember"), "junk"],
            "invite_link": {"@type": "chatInviteLink", "invite_link": "https://t.me/+abc"}}, chatId=-66)
        info = r["result"]
        self.assertEqual((q["basic_group_id"], [(m["name"], m["status"]) for m in info["members"]]),
                         (66, [("Ann", "owner"), ("Bob", "member")]))
        self.assertEqual((info["description"], info["inviteLink"], info["memberCount"]), ("our group", "https://t.me/+abc", 2))
        q, r = self.call(12, "chat.info", "getSupergroupFullInfo", {"@type": "supergroupFullInfo", "description": "club talk",
                                                                    "member_count": 1500, "can_get_members": True}, chatId=-10077)
        self.assertEqual((q["supergroup_id"], r["result"]["memberCount"], r["result"]["canGetMembers"], r["result"]["username"]),
                         (77, 1500, True, "club"))
        self.assertFalse(self.request(self.conn, 13, "chat.info", chatId=999)["ok"])

    def test_members_shared_media_and_counts(self):
        member = lambda uid, status: {"@type": "chatMember", "member_id": {"@type": "messageSenderUser", "user_id": uid},
                                      "status": {"@type": status}}
        q, r = self.call(20, "chat.members", "getSupergroupMembers", {"@type": "chatMembers", "total_count": 1500,
                                                                      "members": [member(501, "chatMemberStatusAdministrator")]},
                         chatId=-10077, query="bo", limit=20)
        self.assertEqual((q["filter"], q["limit"], r["result"]["total"], r["result"]["members"][0]["status"]),
                         ({"@type": "supergroupMembersFilterSearch", "query": "bo"}, 20, 1500, "admin"))
        _, r = self.call(21, "chat.members", "getBasicGroupFullInfo", {"@type": "basicGroupFullInfo", "members": [
            member(500, "chatMemberStatusMember"), member(501, "chatMemberStatusMember")]}, chatId=-66, query="ANN")
        self.assertEqual(([m["name"] for m in r["result"]["members"]], r["result"]["total"]), (["Ann"], 1))
        self.assertFalse(self.request(self.conn, 22, "chat.members", chatId=500)["ok"], "a private chat has no member list")
        q, r = self.call(23, "chat.media", "searchChatMessages", {
            "@type": "foundChatMessages", "total_count": 7, "next_from_message_id": 40,
            "messages": [{"@type": "message", "id": 41, "chat_id": -66, "content": {"@type": "messageDocument", "document": {}}}]},
            chatId=-66, filter="files")
        self.assertEqual((q["filter"], r["result"]["total"], r["result"]["nextFromMessageId"], len(r["result"]["messages"])),
                         ({"@type": "searchMessagesFilterDocument"}, 7, 40, 1))
        self.assertFalse(self.request(self.conn, 24, "chat.media", chatId=-66, filter="secrets")["ok"])
        before = self.sent_count("getChatMessageCount")
        self.send(self.conn, {"id": 25, "cmd": "chat.mediaCounts", "args": {"chatId": -66}})
        self.wait(lambda: self.sent_count("getChatMessageCount") >= before + len(self.d.MEDIA_FILTERS))
        for n, query in enumerate(q for q in self.fake.sent if q.get("@type") == "getChatMessageCount"):
            if n == 0:
                self.td_event({"@type": "error", "code": 400, "message": "nope", "@extra": query["@extra"], "@client_id": 1})
            else:
                self.answer(query, {"@type": "count", "count": n})
        counts = self.read(self.conn, lambda v: v.get("id") == 25)["result"]["counts"]
        self.assertEqual(sorted(counts), sorted(self.d.MEDIA_FILTERS))
        self.assertEqual(sorted(counts.values()), list(range(len(self.d.MEDIA_FILTERS))), "a count that failed is 0")

    def test_leaving_clearing_and_marking_unread(self):
        q, _ = self.call(30, "chat.leave", "leaveChat", {"@type": "ok"}, chatId=-66)
        self.assertEqual(q["chat_id"], -66)
        q, _ = self.call(31, "chat.clearHistory", "deleteChatHistory", {"@type": "ok"}, chatId=500, removeFromList=True)
        self.assertEqual((q["remove_from_chat_list"], q["revoke"]), (True, False))
        q, _ = self.call(32, "chat.markUnread", "toggleChatIsMarkedAsUnread", {"@type": "ok"}, chatId=500, unread=True)
        self.assertTrue(q["is_marked_as_unread"])
        self.assertFalse(self.request(self.conn, 33, "chat.markUnread", chatId=500, unread="yes")["ok"])
        self.assertFalse(self.request(self.conn, 34, "chat.clearHistory", chatId=500, revoke=1)["ok"])

    def test_contacts_and_new_groups_and_channels(self):
        _, r = self.call(40, "contacts.list", "getContacts", {"@type": "users", "total_count": 3, "user_ids": [500, 501, 999]})
        self.assertEqual([(c["userId"], c["name"], c["username"]) for c in r["result"]["contacts"]], [(500, "Ann", "ann"), (501, "Bob", "")])
        q, _ = self.call(41, "contacts.search", "searchContacts", {"@type": "users", "user_ids": [501]}, query="bo")
        self.assertEqual((q["query"], q["limit"]), ("bo", 50))
        q, r = self.call(42, "group.create", "createNewBasicGroupChat", {
            "@type": "createdBasicGroupChat", "chat_id": -99,
            "failed_to_add_members": {"@type": "failedToAddMembers", "failed_to_add_members": [{}]}}, title="  Trip  ", userIds=[500, 501])
        self.assertEqual((q["title"], q["user_ids"], r["result"]), ("Trip", [500, 501], {"chatId": -99, "notAdded": 1}))
        for rid, args in enumerate(({"title": " ", "userIds": []}, {"title": "x" * 200, "userIds": []},
                                    {"title": "ok", "userIds": [True]}, {"title": "ok", "userIds": list(range(1, 300))}), start=43):
            self.assertFalse(self.request(self.conn, rid, "group.create", **args)["ok"], args)
        q, r = self.call(50, "channel.create", "createNewSupergroupChat", {"@type": "chat", "id": -100123},
                         title="News", description="daily", channel=True)
        self.assertEqual((q["is_channel"], q["is_forum"], q["description"], r["result"]), (True, False, "daily", {"chatId": -100123}))
        self.assertFalse(self.request(self.conn, 51, "channel.create", title="News", description="d" * 300)["ok"])

    def test_devices_can_be_listed_and_signed_out(self):
        _, r = self.call(60, "sessions.list", "getActiveSessions", {"@type": "sessions", "inactive_session_ttl_days": 180, "sessions": [
            {"@type": "session", "id": "111", "is_current": False, "application_name": "Telegram Desktop", "device_model": "PC",
             "last_active_date": 100, "device_type": {"@type": "sessionDeviceTypeWindows"}},
            {"@type": "session", "id": "-9223372036854775807", "is_current": True, "application_name": "Omagram", "last_active_date": 50},
            "junk"]})
        self.assertEqual([(s["id"], s["current"], s["type"]) for s in r["result"]["sessions"]],
                         [("-9223372036854775807", True, "unknown"), ("111", False, "windows")])
        self.assertEqual(r["result"]["inactiveDays"], 180)
        q, _ = self.call(61, "session.terminate", "terminateSession", {"@type": "ok"}, id="111")
        self.assertEqual(q["session_id"], 111)
        for rid, bad in enumerate((111, "abc", "9" * 25, "", "9999999999999999999"), start=62):
            self.assertFalse(self.request(self.conn, rid, "session.terminate", id=bad)["ok"], bad)
        self.call(67, "sessions.terminateOthers", "terminateAllOtherSessions", {"@type": "ok"})

    def test_storage_is_counted_and_cleared(self):
        cache = self.root / "lottie"
        cache.mkdir(mode=0o700)
        (cache / ("a" * 64 + ".json")).write_bytes(b"{}" * 10)
        patch = mock.patch.object(self.d, "LOTTIE", cache)
        patch.start()
        self.addCleanup(patch.stop)
        _, r = self.call(70, "storage.stats", "getStorageStatisticsFast", {"@type": "storageStatisticsFast", "files_size": 5000,
                                                                          "file_count": 3, "database_size": 700, "log_size": 0})
        self.assertEqual(r["result"], {"filesSize": 5000, "fileCount": 3, "databaseSize": 700, "logSize": 0, "stickerCacheSize": 20})
        q, r = self.call(71, "storage.clear", "optimizeStorage", {"@type": "storageStatistics", "size": 10, "count": 1, "by_chat": []})
        self.assertEqual((q["size"], q["ttl"], q["count"], q["immunity_delay"], r["result"]), (0, 0, 0, 0, {"remaining": 10}))
        self.assertEqual(list(cache.iterdir()), [], "unpacked stickers go too")

    def test_forum_topics_their_history_and_sending_into_one(self):
        _, r = self.call(80, "topics.list", "getForumTopics", {
            "@type": "forumTopics", "total_count": 1, "next_offset_date": 9, "next_offset_message_id": 8, "next_offset_forum_topic_id": 7,
            "topics": [{"@type": "forumTopic", "unread_count": 4, "is_pinned": True, "order": "123", "last_message": None,
                        "info": {"@type": "forumTopicInfo", "chat_id": -10077, "forum_topic_id": 5, "name": "Rides",
                                 "icon": {"@type": "forumTopicIcon", "color": 7322096}}}, "junk"]}, chatId=-10077)
        topic = r["result"]["topics"][0]
        self.assertEqual((topic["id"], topic["name"], topic["unread"], topic["pinned"], r["result"]["next"]["offsetTopicId"]),
                         (5, "Rides", 4, True, 7))
        q, r = self.call(81, "topic.history", "getForumTopicHistory", {"@type": "messages", "messages": [
            {"@type": "message", "id": 9, "chat_id": -10077, "topic_id": {"@type": "messageTopicForum", "forum_topic_id": 5},
             "content": {"@type": "messageText", "text": {"text": "hi"}}}]}, chatId=-10077, topicId=5)
        self.assertEqual((q["forum_topic_id"], r["result"]["messages"][0]["topicId"]), (5, 5))
        q, _ = self.call(82, "message.send", "sendMessage", {"@type": "message", "id": 10, "chat_id": -10077},
                         chatId=-10077, text="hey", topicId=5)
        self.assertEqual(q["topic_id"], {"@type": "messageTopicForum", "forum_topic_id": 5})
        q, _ = self.call(83, "message.send", "sendMessage", {"@type": "message", "id": 11, "chat_id": -10077}, chatId=-10077, text="hey")
        self.assertIsNone(q["topic_id"])
        self.assertFalse(self.request(self.conn, 84, "message.send", chatId=-10077, text="hey", topicId=0)["ok"])
        q, _ = self.call(85, "chat.draft", "setChatDraftMessage", {"@type": "ok"}, chatId=-10077, text="later", topicId=5)
        self.assertEqual(q["topic_id"]["forum_topic_id"], 5)
        q, _ = self.call(86, "chat.readMentions", "readAllForumTopicMentions", {"@type": "ok"}, chatId=-10077, topicId=5)
        self.assertEqual(q["forum_topic_id"], 5)


    def test_comments_and_reply_threads(self):
        reply_info = {"@type": "messageReplyInfo", "reply_count": 2, "recent_replier_ids": [],
                      "last_read_inbox_message_id": 4, "last_read_outbox_message_id": 0, "last_message_id": 6}
        root = {"@type": "message", "id": 3, "chat_id": -10077, "topic_id": {"@type": "messageTopicThread", "message_thread_id": 3},
                "content": {"@type": "messageText", "text": {"text": "the post"}},
                "interaction_info": {"@type": "messageInteractionInfo", "view_count": 5, "reply_info": reply_info}}
        draft = {"@type": "draftMessage", "content": {"@type": "draftMessageContentText",
                                                      "text": {"@type": "formattedText", "text": "so", "entities": []}}}
        q, r = self.call(140, "thread.open", "getMessageThread", {
            "@type": "messageThreadInfo", "chat_id": -10077, "message_thread_id": 3, "reply_info": reply_info,
            "unread_message_count": 1, "messages": [root], "draft_message": draft}, chatId=-1000500, messageId=900)
        t = r["result"]
        self.assertEqual((q["chat_id"], q["message_id"]), (-1000500, 900))
        self.assertEqual((t["chatId"], t["threadId"], t["fromChatId"], t["fromMessageId"], t["unread"], t["draft"], t["chat"]["id"]),
                         (-10077, 3, -1000500, 900, 1, "so", -10077))
        self.assertEqual((t["replies"], [(m["id"], m["threadId"], m["replies"]["count"]) for m in t["messages"]]),
                         ({"count": 2, "unread": True}, [(3, 3, 2)]))
        _, r = self.call(141, "thread.open", "getMessageThread", {"@type": "messageThreadInfo", "chat_id": 0}, chatId=-10077, messageId=8)
        self.assertFalse(r["ok"], "a message with no thread")

        q, r = self.call(142, "thread.history", "getMessageThreadHistory", {"@type": "messages", "messages": [dict(root, id=6, interaction_info=None)]},
                         chatId=-10077, threadId=3, fromMessageId=6, offset=-10, limit=20)
        self.assertEqual((q["chat_id"], q["message_id"], q["from_message_id"], q["offset"], q["limit"]), (-10077, 3, 6, -10, 20))
        self.assertEqual((r["result"]["threadId"], [(m["id"], m["replies"]) for m in r["result"]["messages"]]), (3, [(6, None)]))

        q, _ = self.call(143, "message.send", "sendMessage", {"@type": "message", "id": 7, "chat_id": -10077},
                         chatId=-10077, text="me too", threadId=3)
        self.assertEqual(q["topic_id"], {"@type": "messageTopicThread", "message_thread_id": 3})
        q, _ = self.call(144, "chat.read", "viewMessages", {"@type": "ok"}, chatId=-10077, messageIds=[6], threadId=3)
        self.assertEqual(q["source"], {"@type": "messageSourceMessageThreadHistory"})
        q, _ = self.call(145, "chat.draft", "setChatDraftMessage", {"@type": "ok"}, chatId=-10077, text="later", threadId=3)
        self.assertEqual(q["topic_id"], {"@type": "messageTopicThread", "message_thread_id": 3})
        self.assertFalse(self.request(self.conn, 146, "message.send", chatId=-10077, text="x", threadId=3, topicId=5)["ok"], "not both")
        self.assertFalse(self.request(self.conn, 147, "chat.readMentions", chatId=-10077, threadId=3)["ok"])
        self.assertFalse(self.request(self.conn, 148, "thread.history", chatId=-10077, threadId=0)["ok"])

    def test_your_profile(self):
        me = {"@type": "user", "id": 777, "first_name": "Ann", "last_name": "Lee", "phone_number": "15550100",
              "usernames": {"@type": "usernames", "active_usernames": ["ann_lee"], "disabled_usernames": [],
                            "editable_username": "ann_lee"},
              "profile_photo": {"@type": "profilePhoto", "id": "5000000000000000001", "has_animation": False}}
        before = self.sent_count("getMe")
        self.send(self.conn, {"id": 150, "cmd": "profile.get", "args": {}})
        asked = self.next_query("getMe", before)
        fulls = self.sent_count("getUserFullInfo")
        self.answer(asked, me)
        full = self.next_query("getUserFullInfo", fulls)
        self.answer(full, {"@type": "userFullInfo", "bio": {"@type": "formattedText", "text": "Hello there", "entities": []}})
        p = self.read(self.conn, lambda v: v.get("id") == 150)["result"]
        self.assertEqual((full["user_id"], p["firstName"], p["lastName"], p["username"], p["bio"], p["phone"], p["photoId"], p["photo"]),
                         (777, "Ann", "Lee", "ann_lee", "Hello there", "15550100", "5000000000000000001", None))

        q, r = self.call(151, "profile.setName", "setName", {"@type": "ok"}, firstName=" Ann ", lastName="")
        self.assertEqual((q["first_name"], q["last_name"], r["ok"]), ("Ann", "", True))
        for rid, args in ((152, {"firstName": "   ", "lastName": ""}), (153, {"firstName": "A\nB", "lastName": ""}),
                          (154, {"firstName": "x" * 65, "lastName": ""}), (155, {"firstName": "Ann", "lastName": 5}),
                          (156, {"firstName": "Ann"})):
            self.assertFalse(self.request(self.conn, rid, "profile.setName", **args)["ok"], args)
        q, _ = self.call(156, "profile.setBio", "setBio", {"@type": "ok"}, bio=" Building things ")
        self.assertEqual(q["bio"], "Building things")
        self.assertFalse(self.request(self.conn, 157, "profile.setBio", bio="two\nlines")["ok"])
        q, _ = self.call(158, "profile.setUsername", "setUsername", {"@type": "ok"}, username="@new_name")
        self.assertEqual(q["username"], "new_name")
        q, _ = self.call(159, "profile.setUsername", "setUsername", {"@type": "ok"}, username="")
        self.assertEqual(q["username"], "", "an empty username removes it")
        for rid, name in ((160, "abcd"), (161, "1abcde"), (162, "has space"), (163, "x" * 33)):
            self.assertFalse(self.request(self.conn, rid, "profile.setUsername", username=name)["ok"], name)

        before = self.sent_count("getMe")
        self.send(self.conn, {"id": 164, "cmd": "profile.deletePhoto", "args": {}})
        asked = self.next_query("getMe", before)
        deletes = self.sent_count("deleteProfilePhoto")
        self.answer(asked, me)
        deleted = self.next_query("deleteProfilePhoto", deletes)
        self.answer(deleted, {"@type": "ok"})
        self.assertTrue(self.read(self.conn, lambda v: v.get("id") == 164)["ok"])
        self.assertEqual(deleted["profile_photo_id"], 5000000000000000001)

        picture = self.root / "me.png"
        picture.write_bytes(b"\x89PNG not really")

        def cut(source, target):
            pathlib.Path(target).write_bytes(b"\xff\xd8 a square")
        with mock.patch.object(self.d.media, "prepare_profile_photo", cut):
            before = self.sent_count("setProfilePhoto")
            self.send(self.conn, {"id": 165, "cmd": "profile.setPhoto", "args": {"path": str(picture)}})
            q = self.next_query("setProfilePhoto", before)
        made = pathlib.Path(q["photo"]["photo"]["path"])
        self.assertEqual((q["photo"]["@type"], q["is_public"], made.parent, made.exists()),
                         ("inputChatPhotoStatic", False, self.root / "rec", True))
        self.answer(q, {"@type": "ok"})
        self.assertTrue(self.read(self.conn, lambda v: v.get("id") == 165)["ok"])
        self.assertFalse(made.exists(), "the square copy goes once Telegram has it")
        with mock.patch.object(self.d.media, "prepare_profile_photo", side_effect=RuntimeError("not a picture")):
            self.assertFalse(self.request(self.conn, 166, "profile.setPhoto", path=str(picture))["ok"])
        self.assertFalse(self.request(self.conn, 167, "profile.setPhoto", path="me.png")["ok"])
        self.assertEqual(list((self.root / "rec").glob("profile-*")), [], "nothing is left behind")

    def test_privacy_and_security(self):
        before = self.sent_count("getUserPrivacySettingRules")
        self.send(self.conn, {"id": 170, "cmd": "privacy.get", "args": {}})
        self.wait(lambda: self.sent_count("getUserPrivacySettingRules") >= before + 9)
        for q in [q for q in self.fake.sent if q.get("@type") == "getUserPrivacySettingRules"][before:]:
            if q["setting"]["@type"] == "userPrivacySettingShowBirthdate":
                self.td_event({"@type": "error", "code": 400, "message": "nope", "@extra": q["@extra"], "@client_id": 1})
            else:
                self.answer(q, {"@type": "userPrivacySettingRules", "rules": [{"@type": "userPrivacySettingRuleAllowContacts"}]})
        settings = self.read(self.conn, lambda v: v.get("id") == 170)["result"]["settings"]
        self.assertEqual(sorted(settings), sorted(["status", "photo", "phone", "findByPhone", "bio", "birthdate", "forwards", "calls", "invites"]))
        self.assertEqual((settings["status"], settings["birthdate"]), ({"base": "contacts", "allowed": 0, "restricted": 0}, None))

        rules = {"@type": "userPrivacySettingRules", "rules": [
            {"@type": "userPrivacySettingRuleAllowUsers", "user_ids": [5]},
            {"@type": "userPrivacySettingRuleRestrictUsers", "user_ids": [9]},
            {"@type": "userPrivacySettingRuleAllowContacts"}]}
        before = self.sent_count("getUserPrivacySettingRules")
        self.send(self.conn, {"id": 171, "cmd": "privacy.set", "args": {"setting": "status", "base": "everybody"}})
        q = self.next_query("getUserPrivacySettingRules", before)
        sets = self.sent_count("setUserPrivacySettingRules")
        self.answer(q, rules)
        q = self.next_query("setUserPrivacySettingRules", sets)
        self.answer(q, {"@type": "ok"})
        r = self.read(self.conn, lambda v: v.get("id") == 171)["result"]
        self.assertEqual((q["setting"], [rule["@type"] for rule in q["rules"]["rules"]], r),
                         ({"@type": "userPrivacySettingShowStatus"}, ["userPrivacySettingRuleRestrictUsers", "userPrivacySettingRuleAllowAll"],
                          {"setting": "status", "base": "everybody", "allowed": 0, "restricted": 1}))
        for rid, args in ((172, {"setting": "findByPhone", "base": "nobody"}), (173, {"setting": "wallpaper", "base": "nobody"}),
                          (174, {"setting": "status", "base": "friends"})):
            self.assertFalse(self.request(self.conn, rid, "privacy.set", **args)["ok"], args)

        q, r = self.call(175, "blocked.list", "getBlockedMessageSenders", {"@type": "messageSenders", "total_count": 3, "senders": [
            {"@type": "messageSenderUser", "user_id": 500}, {"@type": "messageSenderChat", "chat_id": -10077},
            {"@type": "messageSenderUser", "user_id": 0}]})
        self.assertEqual((q["block_list"], q["offset"], q["limit"]), ({"@type": "blockListMain"}, 0, 100))
        self.assertEqual((r["result"]["total"], r["result"]["senders"]),
                         (3, [{"type": "user", "id": 500, "name": "Ann"}, {"type": "chat", "id": -10077, "name": "Club"}]))
        q, _ = self.call(176, "blocked.unblock", "setMessageSenderBlockList", {"@type": "ok"}, type="user", id=500)
        self.assertEqual((q["sender_id"], q["block_list"]), ({"@type": "messageSenderUser", "user_id": 500}, None))
        q, _ = self.call(177, "blocked.unblock", "setMessageSenderBlockList", {"@type": "ok"}, type="chat", id=-10077)
        self.assertEqual(q["sender_id"], {"@type": "messageSenderChat", "chat_id": -10077})
        self.assertFalse(self.request(self.conn, 178, "blocked.unblock", type="user", id=-5)["ok"])

        state = {"@type": "passwordState", "has_password": False, "password_hint": "", "has_recovery_email_address": False,
                 "recovery_email_address_code_info": None, "pending_reset_date": 0}
        _, r = self.call(179, "password.get", "getPasswordState", state)
        self.assertFalse(r["result"]["hasPassword"])
        pending = dict(state, has_password=True, password_hint="pet", recovery_email_address_code_info={
            "@type": "emailAddressAuthenticationCodeInfo", "email_address_pattern": "a***@m.com", "length": 6})
        q, r = self.call(180, "password.set", "setPassword", pending, oldPassword="", newPassword="s3cret-Pw", hint="pet", email="ann@example.com")
        self.assertEqual((q["old_password"], q["new_password"], q["new_hint"], q["set_recovery_email_address"], q["new_recovery_email_address"]),
                         ("", "s3cret-Pw", "pet", True, "ann@example.com"))
        self.assertEqual((r["result"]["hasPassword"], r["result"]["emailCodePattern"]), (True, "a***@m.com"))
        q, _ = self.call(181, "password.set", "setPassword", state, oldPassword="s3cret-Pw", newPassword="", hint="")
        self.assertEqual((q["new_password"], q["new_hint"], q["set_recovery_email_address"]), ("", "", False))
        for rid, args in ((182, {"oldPassword": "", "newPassword": "s3cret-Pw", "hint": "s3cret-Pw"}),
                          (183, {"oldPassword": "", "newPassword": "s3cret-Pw", "hint": "", "email": "not an email"}),
                          (184, {"oldPassword": "", "newPassword": "s3cret-Pw" * 40, "hint": ""})):
            answer = self.request(self.conn, rid, "password.set", **args)
            self.assertFalse(answer["ok"], rid)
            self.assertNotIn("s3cret", answer["error"], "what was typed is never said back")
        q, _ = self.call(185, "password.checkEmailCode", "checkRecoveryEmailAddressCode", state, code=" 123456 ")
        self.assertEqual(q["code"], "123456")
        _, r = self.call(186, "account.ttl", "getAccountTtl", {"@type": "accountTtl", "days": 180})
        self.assertEqual(r["result"], {"days": 180})
        q, r = self.call(187, "account.setTtl", "setAccountTtl", {"@type": "ok"}, days=365)
        self.assertEqual((q["ttl"], r["result"]), ({"@type": "accountTtl", "days": 365}, {"days": 365}))
        self.assertFalse(self.request(self.conn, 188, "account.setTtl", days=10)["ok"])

        scope = {"@type": "scopeNotificationSettings", "mute_for": 0, "sound_id": "-1", "show_preview": True, "use_default_mute_stories": True,
                 "mute_stories": False, "story_sound_id": "-1", "show_story_poster": True, "disable_pinned_message_notifications": False,
                 "disable_mention_notifications": False}
        before = self.sent_count("getScopeNotificationSettings")
        self.send(self.conn, {"id": 189, "cmd": "notifications.get", "args": {}})
        self.wait(lambda: self.sent_count("getScopeNotificationSettings") >= before + 3)
        for q in [q for q in self.fake.sent if q.get("@type") == "getScopeNotificationSettings"][before:]:
            self.answer(q, dict(scope, mute_for=86400) if q["scope"]["@type"] == "notificationSettingsScopeChannelChats" else scope)
        self.assertEqual(self.read(self.conn, lambda v: v.get("id") == 189)["result"]["scopes"],
                         {"private": {"muted": False, "preview": True}, "groups": {"muted": False, "preview": True},
                          "channels": {"muted": True, "preview": True}})
        before = self.sent_count("getScopeNotificationSettings")
        self.send(self.conn, {"id": 190, "cmd": "notifications.set", "args": {"scope": "groups", "preview": False}})
        q = self.next_query("getScopeNotificationSettings", before)
        sets = self.sent_count("setScopeNotificationSettings")
        self.answer(q, scope)
        q = self.next_query("setScopeNotificationSettings", sets)
        self.answer(q, {"@type": "ok"})
        r = self.read(self.conn, lambda v: v.get("id") == 190)["result"]
        self.assertEqual((q["scope"], q["notification_settings"]["show_preview"], q["notification_settings"]["sound_id"], r),
                         ({"@type": "notificationSettingsScopeGroupChats"}, False, -1, {"scope": "groups", "muted": False, "preview": False}))
        for rid, args in ((191, {"scope": "bots", "muted": True}), (192, {"scope": "groups"}), (193, {"scope": "groups", "muted": "yes"})):
            self.assertFalse(self.request(self.conn, rid, "notifications.set", **args)["ok"], args)

    def test_chat_folders(self):
        def info(fid, name):
            return {"@type": "chatFolderInfo", "id": fid, "icon": {"@type": "chatFolderIcon", "name": "Work"}, "color_id": -1,
                    "is_shareable": False, "has_my_invite_links": False,
                    "name": {"@type": "chatFolderName", "text": {"@type": "formattedText", "text": name, "entities": []}}}
        self.td_event({"@type": "updateChatFolders", "chat_folders": [info(2, "Work"), info(3, "Family")], "main_chat_list_position": 0,
                       "are_tags_enabled": False, "@client_id": 1})
        self.read(self.conn, lambda v: v.get("event") == "folders" and len(v["folders"]) == 2)
        before = self.sent_count("getChatFolder")
        self.send(self.conn, {"id": 200, "cmd": "folders.get", "args": {}})
        self.wait(lambda: self.sent_count("getChatFolder") >= before + 2)
        for q in [q for q in self.fake.sent if q.get("@type") == "getChatFolder"][before:]:
            if q["chat_folder_id"] == 3:
                self.td_event({"@type": "error", "code": 400, "message": "gone", "@extra": q["@extra"], "@client_id": 1})
            else:
                self.answer(q, {"@type": "chatFolder", "name": info(2, "Work")["name"], "icon": None, "color_id": -1, "is_shareable": False,
                                "pinned_chat_ids": [], "included_chat_ids": [500], "excluded_chat_ids": [], "exclude_muted": True,
                                "exclude_read": False, "exclude_archived": False, "include_contacts": False, "include_non_contacts": False,
                                "include_bots": False, "include_groups": True, "include_channels": False})
        r = self.read(self.conn, lambda v: v.get("id") == 200)["result"]
        self.assertEqual(([(f["id"], f["name"], f["included"], f["includeGroups"], f["excludeMuted"]) for f in r["folders"]], r["mainPosition"]),
                         ([(2, "Work", [500], True, True)], 0), "a folder Telegram did not answer for is left out")

        q, r = self.call(201, "folder.save", "createChatFolder", {"@type": "chatFolderInfo", "id": 4},
                         name=" Family ", includeContacts=True, included=[500, 500], excluded=[-10077], pinned=[], icon="Home")
        f = q["folder"]
        self.assertEqual((f["name"]["text"]["text"], f["icon"], f["include_contacts"], f["include_groups"], f["included_chat_ids"],
                          f["excluded_chat_ids"], f["color_id"], r["result"]),
                         ("Family", {"@type": "chatFolderIcon", "name": "Home"}, True, False, [500], [-10077], -1, {"id": 4}))
        q, r = self.call(202, "folder.save", "editChatFolder", {"@type": "chatFolderInfo", "id": 2}, id=2, name="Work", includeGroups=True, icon="Nope")
        self.assertEqual((q["chat_folder_id"], q["folder"]["icon"], r["result"]), (2, None, {"id": 2}))
        for rid, args in ((203, {"name": "A much too long name", "includeBots": True}), (204, {"name": "Empty"}),
                          (205, {"name": "X", "includeGroups": "yes"}), (206, {"name": "X", "included": [0]}), (207, {"name": "", "includeBots": True})):
            self.assertFalse(self.request(self.conn, rid, "folder.save", **args)["ok"], args)
        q, _ = self.call(208, "folder.delete", "deleteChatFolder", {"@type": "ok"}, id=3)
        self.assertEqual((q["chat_folder_id"], q["leave_chat_ids"]), (3, []))
        q, _ = self.call(209, "folders.reorder", "reorderChatFolders", {"@type": "ok"}, ids=[3, 2])
        self.assertEqual((q["chat_folder_ids"], q["main_chat_list_position"]), ([3, 2], 0))
        self.assertFalse(self.request(self.conn, 210, "folders.reorder", ids=[2])["ok"])

    def test_every_reaction_a_message_may_get(self):
        many = [{"@type": "availableReaction", "type": {"@type": "reactionTypeEmoji", "emoji": chr(0x1F600 + i)}, "needs_premium": False}
                for i in range(60)]
        answer = {"@type": "availableReactions", "top_reactions": [], "recent_reactions": [], "popular_reactions": many}
        _, r = self.call(280, "reactions.available", "getMessageAvailableReactions", answer, chatId=500, messageId=7)
        self.assertEqual(len(r["result"]["emoji"]), 48, "the menu's row needs only the first")
        _, r = self.call(281, "reactions.available", "getMessageAvailableReactions", answer, chatId=500, messageId=7, all=True)
        self.assertEqual(len(r["result"]["emoji"]), 60)

    def test_a_chat_set_to_silent_sends_everything_without_sound(self):
        q, r = self.call(270, "chat.setSilent", "toggleChatDefaultDisableNotification", {"@type": "ok"}, chatId=500, silent=True)
        self.assertEqual((q["chat_id"], q["default_disable_notification"], r["result"]), (500, True, {"silent": True}))
        self.assertFalse(self.request(self.conn, 271, "chat.setSilent", chatId=500, silent="yes")["ok"])
        self.td_event({"@type": "updateChatDefaultDisableNotification", "chat_id": 500, "default_disable_notification": True,
                       "@client_id": 1})
        self.read(self.conn, lambda v: v.get("event") == "chat" and v["chat"]["id"] == 500 and v["chat"]["silent"] is True)
        q, _ = self.call(272, "message.send", "sendMessage", {"@type": "message", "id": 20, "chat_id": 500}, chatId=500, text="quiet")
        self.assertIs(q["options"]["disable_notification"], True, "every message there goes without sound")
        q, _ = self.call(273, "message.send", "sendMessage", {"@type": "message", "id": 21, "chat_id": 500}, chatId=500, text="loud",
                         silent=False)
        self.assertIsNone(q["options"], "unless you send one with sound")
        q, _ = self.call(274, "message.send", "sendMessage", {"@type": "message", "id": 22, "chat_id": -66}, chatId=-66, text="hi")
        self.assertIsNone(q["options"], "other chats are not touched")

    def test_reactions_count_as_seen_in_the_chat_on_screen(self):
        self.td_event({"@type": "updateChatUnreadReactionCount", "chat_id": 500, "unread_reaction_count": 2, "@client_id": 1})
        self.read(self.conn, lambda v: v.get("event") == "chat" and v["chat"]["id"] == 500 and v["chat"]["unreadReactions"] == 2)
        self.request(self.conn, 259, "hello")   # everything before it has been handled
        self.assertEqual(self.sent_count("readAllChatReactions"), 0, "not while nobody looks at the chat")
        before = self.sent_count("readAllChatReactions")
        self.assertTrue(self.request(self.conn, 260, "ui.focus", chatId=500)["ok"])
        self.assertEqual(self.next_query("readAllChatReactions", before)["chat_id"], 500)
        before = self.sent_count("readAllChatReactions")   # one arriving while it is on screen is seen at once too
        self.td_event({"@type": "updateMessageUnreadReactions", "chat_id": 500, "message_id": 9, "unread_reactions": [],
                       "unread_reaction_count": 1, "@client_id": 1})
        self.assertEqual(self.next_query("readAllChatReactions", before)["chat_id"], 500)
        self.assertTrue(self.request(self.conn, 261, "settings.reactions", seen=False)["ok"])
        count = self.sent_count("readAllChatReactions")
        self.td_event({"@type": "updateChatUnreadReactionCount", "chat_id": 500, "unread_reaction_count": 3, "@client_id": 1})
        self.request(self.conn, 262, "hello")
        self.assertEqual(self.sent_count("readAllChatReactions"), count, "with the setting off they wait to be seen")
        self.assertTrue(self.request(self.conn, 263, "settings.reactions", seen=True)["ok"])
        self.assertTrue(self.request(self.conn, 264, "ui.focus", chatId=0)["ok"])
        self.td_event({"@type": "updateChatUnreadReactionCount", "chat_id": 500, "unread_reaction_count": 4, "@client_id": 1})
        self.request(self.conn, 265, "hello")
        self.assertEqual(self.sent_count("readAllChatReactions"), count, "nor once the window looks away")

    def test_disappearing_messages(self):
        q, r = self.call(250, "chat.setAutoDelete", "setChatMessageAutoDeleteTime", {"@type": "ok"}, chatId=500, seconds=604800)
        self.assertEqual((q["chat_id"], q["message_auto_delete_time"], r["result"]), (500, 604800, {"seconds": 604800}))
        for rid, seconds in ((251, 3600), (252, -86400), (253, 366 * 86400)):
            self.assertFalse(self.request(self.conn, rid, "chat.setAutoDelete", chatId=500, seconds=seconds)["ok"], seconds)
        _, r = self.call(254, "autoDelete.default", "getDefaultMessageAutoDeleteTime", {"@type": "messageAutoDeleteTime", "time": 86400})
        self.assertEqual(r["result"], {"seconds": 86400})
        q, _ = self.call(255, "autoDelete.setDefault", "setDefaultMessageAutoDeleteTime", {"@type": "ok"}, seconds=2678400)
        self.assertEqual(q["message_auto_delete_time"], {"@type": "messageAutoDeleteTime", "time": 2678400})
        self.assertFalse(self.request(self.conn, 256, "autoDelete.setDefault", seconds=60)["ok"])
        self.td_event({"@type": "updateChatMessageAutoDeleteTime", "chat_id": -66, "message_auto_delete_time": 86400, "@client_id": 1})
        chat = self.read(self.conn, lambda v: v.get("event") == "chat" and v["chat"]["id"] == -66)["chat"]
        self.assertEqual((chat["autoDelete"], chat["canSetAutoDelete"]), (86400, True), "the group's owner may")
        chats = {c["id"]: c for c in self.request(self.conn, 257, "chats.list", list="main")["result"]["chats"]}
        self.assertEqual((chats[500]["canSetAutoDelete"], chats[-10077]["canSetAutoDelete"]), (True, False))

    def test_reactions_viewers_and_dates(self):
        q, r = self.call(240, "chat.nextReaction", "searchChatMessages", {"@type": "foundChatMessages", "messages": [
            {"@type": "message", "id": 30}, {"@type": "message", "id": 12}]}, chatId=-10077)
        self.assertEqual((q["filter"], r["result"]), ({"@type": "searchMessagesFilterUnreadReaction"}, {"messageId": 12}))
        q, _ = self.call(241, "chat.readReactions", "readAllChatReactions", {"@type": "ok"}, chatId=-10077)
        self.assertEqual(q["chat_id"], -10077)
        q, _ = self.call(246, "chat.readReactions", "readAllForumTopicReactions", {"@type": "ok"}, chatId=-10077, topicId=5)
        self.assertEqual((q["chat_id"], q["forum_topic_id"]), (-10077, 5))
        self.assertFalse(self.request(self.conn, 247, "chat.readReactions", chatId=-10077, threadId=9)["ok"])
        q, r = self.call(242, "message.reactions", "getMessageAddedReactions", {"@type": "addedReactions", "total_count": 2, "next_offset": "n1",
            "reactions": [{"@type": "addedReaction", "type": {"@type": "reactionTypeEmoji", "emoji": "❤"}, "date": 1789000000, "is_outgoing": False,
                           "sender_id": {"@type": "messageSenderUser", "user_id": 500}},
                          {"@type": "addedReaction", "type": {"@type": "reactionTypeCustomEmoji", "custom_emoji_id": "5"}, "date": 1789000001,
                           "sender_id": {"@type": "messageSenderChat", "chat_id": -10077}}]}, chatId=-10077, messageId=7)
        self.assertEqual((q["reaction_type"], q["offset"], q["limit"], r["result"]["total"], r["result"]["nextOffset"]), (None, "", 50, 2, "n1"))
        self.assertEqual([(x["type"], x["id"], x["name"], x["emoji"]) for x in r["result"]["reactions"]],
                         [("user", 500, "Ann", "❤"), ("chat", -10077, "Club", "")])
        _, r = self.call(243, "message.viewers", "getMessageViewers", {"@type": "messageViewers", "viewers": [
            {"@type": "messageViewer", "user_id": 501, "view_date": 1789000005}, {"@type": "messageViewer", "user_id": 0}]}, chatId=-10077, messageId=7)
        self.assertEqual(r["result"]["viewers"], [{"userId": 501, "name": "Bob", "date": 1789000005}])
        q, r = self.call(244, "chat.messageByDate", "getChatMessageByDate", {"@type": "message", "id": 99, "chat_id": -10077}, chatId=-10077, date=1788998400)
        self.assertEqual((q["date"], r["result"]), (1788998400, {"messageId": 99}))
        self.assertFalse(self.request(self.conn, 245, "chat.messageByDate", chatId=-10077, date=-5)["ok"])

    def test_polls_and_quizzes(self):
        q, _ = self.call(230, "message.sendPoll", "sendMessage", {"@type": "message", "id": 5, "chat_id": -10077},
                         chatId=-10077, question=" Lunch? ", options=["Pizza", " Soup "], multiple=True, anonymous=False)
        poll = q["input_message_content"]
        self.assertEqual((poll["question"]["text"], [o["text"]["text"] for o in poll["options"]], poll["is_anonymous"],
                          poll["allows_multiple_answers"], poll["allows_revoting"], poll["type"]),
                         ("Lunch?", ["Pizza", "Soup"], False, True, True, {"@type": "inputPollTypeRegular", "allow_adding_options": False}))
        q, _ = self.call(231, "message.sendPoll", "sendMessage", {"@type": "message", "id": 6, "chat_id": -10077},
                         chatId=-10077, question="2 + 2?", options=["3", "4", "5"], quiz=True, correct=1, explanation="Count them")
        quiz = q["input_message_content"]
        self.assertEqual((quiz["is_anonymous"], quiz["allows_revoting"], quiz["type"]["correct_option_ids"], quiz["type"]["explanation"]["text"]),
                         (True, False, [1], "Count them"))
        for rid, args in ((232, {"question": "", "options": ["a", "b"]}), (233, {"question": "Q", "options": ["only one"]}),
                          (234, {"question": "Q", "options": ["a"] * 13}), (235, {"question": "Q", "options": ["Same", "same"]}),
                          (236, {"question": "Q", "options": ["a", "b"], "quiz": True, "correct": 2}),
                          (237, {"question": "Q", "options": ["a", "b"], "quiz": True, "multiple": True, "correct": 0}),
                          (238, {"question": "Q", "options": ["a", "x" * 101]}), (239, {"question": "Q", "options": ["a", "b"], "anonymous": "no"})):
            self.assertFalse(self.request(self.conn, rid, "message.sendPoll", chatId=-10077, **args)["ok"], args)

    def test_dice_contact_cards_and_locations(self):
        q, _ = self.call(220, "message.sendDice", "sendMessage", {"@type": "message", "id": 1, "chat_id": 500}, chatId=500, emoji="🎯")
        self.assertEqual(q["input_message_content"], {"@type": "inputMessageDice", "emoji": "🎯", "clear_draft": False})
        self.assertFalse(self.request(self.conn, 221, "message.sendDice", chatId=500, emoji="🍕")["ok"])
        q, _ = self.call(222, "message.sendContact", "sendMessage", {"@type": "message", "id": 2, "chat_id": -10077},
                         chatId=-10077, userId=500, replyToMessageId=7)
        self.assertEqual((q["input_message_content"]["contact"], q["reply_to"]["message_id"]),
                         ({"@type": "contact", "phone_number": "380671234567", "first_name": "Ann", "last_name": "", "vcard": "",
                           "user_id": 500}, 7))
        q, _ = self.call(223, "message.sendContact", "sendMessage", {"@type": "message", "id": 3, "chat_id": -10077}, chatId=-10077, userId=501)
        self.assertEqual(q["input_message_content"]["contact"]["phone_number"], "", "a number Telegram does not show you stays out")
        self.assertFalse(self.request(self.conn, 224, "message.sendContact", chatId=-10077, userId=999)["ok"])
        q, _ = self.call(225, "message.sendLocation", "sendMessage", {"@type": "message", "id": 4, "chat_id": -10077},
                         chatId=-10077, latitude=50.4501, longitude=30.5234, threadId=3)
        place = q["input_message_content"]["location"]
        self.assertEqual((place["latitude"], place["longitude"], q["topic_id"]),
                         (50.4501, 30.5234, {"@type": "messageTopicThread", "message_thread_id": 3}))
        for rid, args in ((226, {"latitude": 91, "longitude": 0}), (227, {"latitude": "50", "longitude": 30}), (228, {"latitude": True, "longitude": 1})):
            self.assertFalse(self.request(self.conn, rid, "message.sendLocation", chatId=500, **args)["ok"], args)

    def test_mention_and_command_suggestions(self):
        def member(uid):
            return {"@type": "chatMember", "member_id": {"@type": "messageSenderUser", "user_id": uid},
                    "status": {"@type": "chatMemberStatusMember"}}
        found = {"@type": "chatMembers", "total_count": 2, "members": [member(500), member(501)]}
        q, r = self.call(120, "chat.mentions", "searchChatMembers", found, chatId=-10077, query="a", topicId=5)
        self.assertEqual((q["chat_id"], q["query"], q["limit"], q["filter"]),
                         (-10077, "a", 20, {"@type": "chatMembersFilterMention",
                                            "topic_id": {"@type": "messageTopicForum", "forum_topic_id": 5}}))
        self.assertEqual(r["result"]["people"], [{"userId": 500, "name": "Ann", "username": "ann", "bot": False},
                                                  {"userId": 501, "name": "Bob", "username": "", "bot": False}])
        self.assertEqual(self.request(self.conn, 121, "chat.mentions", chatId=500, query="a")["result"]["people"], [],
                         "no one to mention in a private chat")
        self.assertFalse(self.request(self.conn, 122, "chat.mentions", chatId=-66, query="x" * 65)["ok"])

        for update in (
            {"@type": "updateUser", "user": {"@type": "user", "id": 600, "first_name": "Helper", "type": {"@type": "userTypeBot"},
                                              "usernames": {"@type": "usernames", "active_usernames": ["helpbot"]}}},
            {"@type": "updateNewChat", "chat": {"@type": "chat", "id": 600, "title": "Helper",
                                                "type": {"@type": "chatTypePrivate", "user_id": 600}}},
        ):
            self.td_event(dict(update, **{"@client_id": 1}))
        self.read(self.conn, lambda v: v.get("event") == "chat" and v["chat"]["id"] == 600)
        info = {"@type": "userFullInfo", "bot_info": {"@type": "botInfo", "commands": [
            {"@type": "botCommand", "command": "start", "description": "Start over"},
            {"@type": "botCommand", "command": "not a command", "description": "dropped"}]}}
        q, r = self.call(123, "chat.commands", "getUserFullInfo", info, chatId=600)
        self.assertEqual((q["user_id"], r["result"]["commands"]),
                         (600, [{"command": "start", "description": "Start over", "botId": 600, "bot": "helpbot"}]))
        group = {"@type": "basicGroupFullInfo", "bot_commands": [{"@type": "botCommands", "bot_user_id": 600, "commands": [
            {"@type": "botCommand", "command": "help", "description": "Help"}]}]}
        q, r = self.call(124, "chat.commands", "getBasicGroupFullInfo", group, chatId=-66)
        self.assertEqual((q["basic_group_id"], [c["command"] for c in r["result"]["commands"]]), (66, ["help"]))
        self.assertEqual(self.request(self.conn, 125, "chat.commands", chatId=500)["result"]["commands"], [],
                         "a person has no commands")


    def test_joining_a_public_group_or_channel(self):
        q, r = self.call(130, "chat.join", "joinChat", {"@type": "chatJoinResultSuccess", "chat_id": -10077}, chatId=-10077)
        self.assertEqual((q["chat_id"], r["result"]), (-10077, {"chatId": -10077, "state": "joined"}))
        _, r = self.call(131, "chat.join", "joinChat", {"@type": "chatJoinResultRequestSent"}, chatId=-10077)
        self.assertEqual(r["result"], {"chatId": -10077, "state": "requested"})
        for rid, chat_id in ((132, 500), (133, -66), (134, -424242)):
            self.assertFalse(self.request(self.conn, rid, "chat.join", chatId=chat_id)["ok"], "a private chat, a basic group, an unknown chat")
        q, r = self.call(135, "chats.search", "searchPublicChats", {"@type": "chats", "chat_ids": [-10077, 424242]},
                         query="club", public=True)
        self.assertEqual((q["query"], q["type_filter"], [c["id"] for c in r["result"]["chats"]]), ("club", None, [-10077]))
        _, r = self.call(136, "chat.open", "openChat", {"@type": "ok"}, chatId=-10077)
        self.assertEqual((r["result"]["chat"]["id"], r["result"]["chat"]["supergroup"]), (-10077, True))


class Extras(Harness):
    def setUp(self):
        super().setUp()
        self.conn = self.connect()
        self.sign_in(self.conn)
        for update in (
            {"@type": "updateUser", "user": {"@type": "user", "id": 500, "first_name": "Ann"}},
            {"@type": "updateNewChat", "chat": {"@type": "chat", "id": 500, "title": "Ann", "type": {"@type": "chatTypePrivate", "user_id": 500}}},
            {"@type": "updateSecretChat", "secret_chat": {"@type": "secretChat", "id": 9, "user_id": 500, "is_outbound": True,
                                                          "state": {"@type": "secretChatStateReady"},
                                                          "key_hash": base64.b64encode(bytes(range(36))).decode()}},
            {"@type": "updateNewChat", "chat": {"@type": "chat", "id": -9, "title": "Ann",
                                                "type": {"@type": "chatTypeSecret", "secret_chat_id": 9, "user_id": 500}}},
        ):
            self.td_event(dict(update, **{"@client_id": 1}))
        self.secret_chat = self.read(self.conn, lambda v: v.get("event") == "chat" and v["chat"]["id"] == -9)["chat"]

    def test_silent_and_scheduled_sending(self):
        sent = {"@type": "message", "id": 1, "chat_id": 500}
        q, _ = self.call(1, "message.send", "sendMessage", sent, chatId=500, text="shh", silent=True)
        self.assertEqual((q["options"]["disable_notification"], q["options"]["scheduling_state"]), (True, None))
        later = int(time.time()) + 3600
        q, _ = self.call(2, "message.send", "sendMessage", sent, chatId=500, text="later", sendAt=later)
        self.assertEqual(q["options"]["scheduling_state"], {"@type": "messageSchedulingStateSendAtDate", "send_date": later, "repeat_period": 0})
        q, _ = self.call(3, "message.send", "sendMessage", sent, chatId=500, text="online", sendAt=-1)
        self.assertEqual(q["options"]["scheduling_state"], {"@type": "messageSchedulingStateSendWhenOnline"})
        q, _ = self.call(4, "message.send", "sendMessage", sent, chatId=500, text="now")
        self.assertIsNone(q["options"])
        for rid, bad in enumerate(({"sendAt": int(time.time()) - 60}, {"sendAt": int(time.time()) + 400 * 86400},
                                   {"silent": "yes"}, {"sendAt": -2}), start=5):
            self.assertFalse(self.request(self.conn, rid, "message.send", chatId=500, text="x", **bad)["ok"], bad)
        _, r = self.call(10, "chat.scheduled", "getChatScheduledMessages", {"@type": "messages", "messages": [
            {"@type": "message", "id": 77, "chat_id": 500, "content": {"@type": "messageText", "text": {"text": "later"}},
             "scheduling_state": {"@type": "messageSchedulingStateSendAtDate", "send_date": later}}]}, chatId=500)
        self.assertEqual(r["result"]["messages"][0]["sendAt"], later)
        q, _ = self.call(11, "message.reschedule", "editMessageSchedulingState", {"@type": "ok"}, chatId=500, messageId=77, sendAt=0)
        self.assertIsNone(q["scheduling_state"], "0 sends it now")
        q, _ = self.call(12, "message.reschedule", "editMessageSchedulingState", {"@type": "ok"}, chatId=500, messageId=77, sendAt=later + 60)
        self.assertEqual(q["scheduling_state"]["send_date"], later + 60)

    def test_translation(self):
        q, r = self.call(20, "message.translate", "translateMessageText", {"@type": "formattedText", "text": "hello", "entities": []},
                         chatId=500, messageId=7, to="en")
        self.assertEqual((q["to_language_code"], q["tone"], r["result"]), ("en", "", {"text": "hello", "entities": [], "to": "en"}))
        self.assertFalse(self.request(self.conn, 21, "message.translate", chatId=500, messageId=7, to="english please")["ok"])

    def gif(self, fid):
        return {"@type": "animation", "duration": 3, "width": 320, "height": 240, "mime_type": "video/mp4",
                "animation": {"@type": "file", "id": fid, "size": 1000, "local": {}}}

    def test_gifs_saved_found_through_the_gif_bot_and_sent(self):
        _, r = self.call(30, "gifs.saved", "getSavedAnimations", {"@type": "animations", "animations": [self.gif(41), "junk"]})
        self.assertEqual([g["file"]["id"] for g in r["result"]["gifs"]], [41])
        before = self.sent_count("searchPublicChat")
        self.send(self.conn, {"id": 31, "cmd": "gifs.search", "args": {"chatId": 500, "query": "cats"}})
        q = self.next_query("searchPublicChat", before)
        self.assertEqual(q["username"], "gif")
        before = self.sent_count("getInlineQueryResults")
        self.answer(q, {"@type": "chat", "id": 101, "type": {"@type": "chatTypePrivate", "user_id": 101}})
        q = self.next_query("getInlineQueryResults", before)
        self.assertEqual((q["bot_user_id"], q["chat_id"], q["query"]), (101, 500, "cats"))
        self.answer(q, {"@type": "inlineQueryResults", "inline_query_id": "123456789", "next_offset": "25", "results": [
            {"@type": "inlineQueryResultAnimation", "id": "r1", "animation": self.gif(42)}, {"@type": "inlineQueryResultPhoto", "id": "p"}]})
        r = self.read(self.conn, lambda v: v.get("id") == 31)["result"]
        self.assertEqual((r["queryId"], r["nextOffset"], [x["id"] for x in r["results"]]), ("123456789", "25", ["r1"]))
        lookups = self.sent_count("searchPublicChat")
        q, _ = self.call(32, "gifs.search", "getInlineQueryResults", {"@type": "inlineQueryResults", "inline_query_id": "5", "results": []},
                         chatId=500, query="dogs", offset="25")
        self.assertEqual((self.sent_count("searchPublicChat"), q["offset"]), (lookups, "25"), "the bot is looked up once")
        q, _ = self.call(33, "message.sendGif", "sendInlineQueryResultMessage", {"@type": "message", "id": 5, "chat_id": 500},
                         chatId=500, queryId="123456789", resultId="r1")
        self.assertEqual((q["query_id"], q["result_id"], q["hide_via_bot"]), (123456789, "r1", True))
        q, _ = self.call(34, "message.sendGif", "sendMessage", {"@type": "message", "id": 6, "chat_id": 500},
                         chatId=500, fileId=41, width=320, height=240, duration=3)
        self.assertEqual(q["input_message_content"]["animation"]["animation"], {"@type": "inputFileId", "id": 41})
        self.assertFalse(self.request(self.conn, 35, "message.sendGif", chatId=500, queryId="x", resultId="r1")["ok"])

    def test_custom_emoji_secret_chats_and_calls(self):
        sticker = {"@type": "sticker", "id": "1", "width": 100, "height": 100, "emoji": "😀", "format": {"@type": "stickerFormatWebp"},
                   "full_type": {"@type": "stickerFullTypeCustomEmoji", "custom_emoji_id": "5368324170671202286"},
                   "sticker": {"@type": "file", "id": 88, "size": 900, "local": {}}}
        q, r = self.call(40, "customEmoji.get", "getCustomEmojiStickers", {"@type": "stickers", "stickers": [sticker, "junk"]},
                         ids=["5368324170671202286"])
        self.assertEqual((q["custom_emoji_ids"], r["result"]["emoji"][0]["id"], r["result"]["emoji"][0]["file"]["id"]),
                         ([5368324170671202286], "5368324170671202286", 88))
        for rid, bad in enumerate(([], ["x"], [5], ["9" * 25]), start=41):
            self.assertFalse(self.request(self.conn, rid, "customEmoji.get", ids=bad)["ok"], bad)
        self.assertEqual(self.secret_chat["secret"], {"state": "ready", "outbound": True})
        self.assertNotIn("keyHash", json.dumps(self.secret_chat), "the key fingerprint is on the info page only")
        _, r = self.call(46, "chat.info", "getUserFullInfo", {"@type": "userFullInfo"}, chatId=-9)
        self.assertEqual(r["result"]["keyHash"].split()[:2], ["00010203", "04050607"])
        q, r = self.call(47, "secret.create", "createNewSecretChat", {"@type": "chat", "id": -10}, userId=500)
        self.assertEqual((q["user_id"], r["result"]), (500, {"chatId": -10}))
        q, _ = self.call(48, "secret.close", "closeSecretChat", {"@type": "ok"}, chatId=-9)
        self.assertEqual(q["secret_chat_id"], 9)
        self.assertFalse(self.request(self.conn, 49, "secret.close", chatId=500)["ok"], "not a secret chat")
        self.td_event({"@type": "updateCall", "@client_id": 1, "call": {"@type": "call", "id": 3, "user_id": 500, "is_outgoing": False,
                                                                        "is_video": True, "state": {"@type": "callStatePending"}}})
        call = self.read(self.conn, lambda v: v.get("event") == "call")["call"]
        self.assertEqual((call["id"], call["name"], call["video"], call["state"]), (3, "Ann", True, "pending"))
        self.assertEqual([c["id"] for c in self.request(self.conn, 50, "hello")["result"]["calls"]], [3], "a window opened now sees it")
        q, _ = self.call(51, "call.decline", "discardCall", {"@type": "ok"}, callId=3)
        self.assertEqual((q["call_id"], q["is_video"], q["duration"]), (3, True, 0))

    def test_stories_are_listed_fetched_opened_and_closed(self):
        self.td_event({"@type": "updateChatActiveStories", "@client_id": 1, "active_stories": {
            "@type": "chatActiveStories", "chat_id": 500, "list": {"@type": "storyListMain"}, "order": 9, "max_read_story_id": 0,
            "stories": [{"@type": "storyInfo", "story_id": 3, "date": 1789000000}]}})
        stories = self.read(self.conn, lambda v: v.get("event") == "stories")["stories"]
        self.assertEqual((stories["chatId"], [x["id"] for x in stories["stories"]]), (500, [3]))
        self.assertEqual([a["chatId"] for a in self.request(self.conn, 60, "hello", window=True)["result"]["stories"]], [500],
                         "a window opened now sees them")
        story = {"@type": "story", "id": 3, "poster_chat_id": 500, "date": 1789000000, "can_be_forwarded": True,
                 "caption": {"@type": "formattedText", "text": "", "entities": []}, "content": {"@type": "storyContentUnsupported"}}
        q, r = self.call(61, "story.get", "getStory", story, chatId=500, storyId=3)
        self.assertEqual((q["story_poster_chat_id"], q["story_id"], q["only_local"], r["result"]["story"]["kind"]), (500, 3, False, "unsupported"))
        q, _ = self.call(62, "story.open", "openStory", {"@type": "ok"}, chatId=500, storyId=3)
        self.assertEqual((q["story_poster_chat_id"], q["story_id"]), (500, 3))
        q, _ = self.call(63, "story.close", "closeStory", {"@type": "ok"}, chatId=500, storyId=3)
        self.assertEqual((q["story_poster_chat_id"], q["story_id"]), (500, 3))
        for rid, bad in enumerate(({"chatId": 500}, {"chatId": 500, "storyId": 0}, {"chatId": 500, "storyId": 2 ** 31}), start=64):
            self.assertFalse(self.request(self.conn, rid, "story.open", **bad)["ok"], bad)


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

    def test_a_round_video_the_service_records_is_sent_and_one_recording_at_a_time(self):
        def capture_argv(target, preview, inputs=None):
            pathlib.Path(target).write_bytes(b"mp4")
            pathlib.Path(preview).write_bytes(bytes((0xFF, 0xD8)))
            return [sys.executable, "-c", "import signal, sys, time; signal.signal(signal.SIGINT, lambda *a: sys.exit(0)); time.sleep(30)"]
        patch = mock.patch.object(self.d.media, "video_capture_argv", capture_argv)
        patch.start()
        self.addCleanup(patch.stop)
        answer = self.request(self.conn, 1, "videonote.record", chatId=42)
        preview = pathlib.Path(answer["result"]["preview"])
        self.assertEqual((preview.parent, preview.exists()), (self.d.media.REC, True))
        self.read(self.conn, lambda v: v.get("event") == "recording" and v.get("state") == "video")
        self.assertFalse(self.request(self.conn, 2, "voice.start", chatId=42)["ok"], "one recording at a time")
        self.assertFalse(self.request(self.conn, 3, "voice.stop", send=True)["ok"], "a video is not finished as a voice message")
        before = self.fake.sent_types().count("sendMessage")
        self.send(self.conn, {"id": 4, "cmd": "videonote.stop", "args": {"send": True, "replyToMessageId": 9}})
        query = self.sent_after(before)
        note = query["input_message_content"]["video_note"]
        self.assertEqual((query["chat_id"], query["reply_to"]["message_id"], note["duration"], note["length"]),
                         (42, 9, 7, self.d.media.NOTE_SIZE))
        self.wait(lambda: not preview.exists())
        self.assertFalse(self.request(self.conn, 5, "videonote.stop", send=True)["ok"], "nothing is recording now")
        self.assertTrue(self.request(self.conn, 6, "videonote.record", chatId=42)["ok"])
        self.assertTrue(self.request(self.conn, 7, "videonote.stop", send=False)["ok"])
        self.wait(lambda: not any(p.name.startswith("note-") for p in self.d.media.REC.iterdir()))

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

    def test_quiet_holds_notifications_and_sounds_back(self):
        self.assertIs(self.daemon.do_not_disturb(), False)
        other = self.connect()
        answer = self.request(self.conn, 1, "settings.quiet", quiet=True)
        self.assertTrue(answer["ok"], answer)
        self.assertIs(answer["result"]["settings"]["quiet"], True)
        self.assertIs(self.daemon.do_not_disturb(), True)          # what the sounds ask
        self.assertIs(json.loads(self.d.prefs.SETTINGS.read_text())["quiet"], True)
        event = self.read(other, lambda v: v.get("event") == "settings")
        self.assertIs(event["settings"]["quiet"], True)

        shown = []
        self.daemon.notifier.show = lambda *a, **k: shown.append(a) or True
        self.daemon.on_notification_group({"chat_id": 7, "total_count": 1, "added_notifications": [
            {"id": 1, "type": {"@type": "notificationTypeNewMessage", "message": {}}}]})
        self.assertEqual(shown, [], "nothing pops up while quiet")

        self.assertTrue(self.request(self.conn, 2, "settings.set", settings={"shortcuts": {}})["ok"])
        self.assertIs(json.loads(self.d.prefs.SETTINGS.read_text())["quiet"], True, "the shortcuts page leaves it alone")
        self.assertTrue(self.request(self.conn, 3, "settings.quiet", quiet=False)["ok"])
        self.assertIs(self.daemon.do_not_disturb(), False)
        for rid, value in ((4, "maybe"), (5, 1), (6, None)):
            self.assertFalse(self.request(self.conn, rid, "settings.quiet", quiet=value)["ok"], value)

    def test_quit_tells_the_window_to_close(self):
        other = self.connect()
        answer = self.request(self.conn, 1, "app.quit")
        self.assertTrue(answer["ok"], answer)
        self.assertEqual(self.read(other, lambda v: v.get("event") == "quit")["event"], "quit")

    def test_settings_come_with_hello_and_are_saved_and_shared(self):
        hello = self.request(self.conn, 1, "hello")["result"]
        self.assertEqual(hello["settings"], {"shortcuts": {}, "globalShortcuts": {}, "playbackRate": 1,
                                             "autoDownload": {"photos": True, "gifs": True, "videos": 0, "files": 0},
                                             "reactionsSeen": True, "emoji": {"tone": 0, "recents": {}},
                                             "sounds": {"style": "drop", "variants": {}}, "quiet": False})
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
        answer = self.request(self.conn, 40, "settings.playback", rate=1.5)
        self.assertEqual(answer["result"]["settings"]["playbackRate"], 1.5)
        self.assertEqual(self.read(other, lambda v: v.get("event") == "settings")["settings"]["playbackRate"], 1.5)
        self.assertTrue(self.request(self.conn, 41, "settings.set", settings={"shortcuts": {"window.voice": ["Ctrl+Alt+R"]}})["ok"])
        self.assertEqual(json.loads(self.d.prefs.SETTINGS.read_text())["playbackRate"], 1.5, "the settings page leaves the speed alone")
        for rid, rate in ((42, 3), (43, True), (44, "2")):
            self.assertFalse(self.request(self.conn, rid, "settings.playback", rate=rate)["ok"])
        mine = {"photos": False, "gifs": True, "videos": 10, "files": 0}
        answer = self.request(self.conn, 45, "settings.autoDownload", rules=mine)
        self.assertEqual(answer["result"]["settings"]["autoDownload"], mine)
        self.read(other, lambda v: v.get("event") == "settings" and v["settings"]["autoDownload"] == mine)
        self.assertTrue(self.request(self.conn, 46, "settings.set", settings={"shortcuts": {}})["ok"])
        saved = json.loads(self.d.prefs.SETTINGS.read_text())
        self.assertEqual((saved["autoDownload"], saved["playbackRate"]), (mine, 1.5), "the shortcuts page leaves both alone")
        for rid, rules in ((47, {"videos": 20}), (48, "all"), (49, {"photos": 1})):
            self.assertFalse(self.request(self.conn, rid, "settings.autoDownload", rules=rules)["ok"], rules)
        answer = self.request(self.conn, 50, "settings.reactions", seen=False)
        self.assertIs(answer["result"]["settings"]["reactionsSeen"], False)
        self.assertTrue(self.request(self.conn, 51, "settings.set", settings={"shortcuts": {}})["ok"])
        self.assertIs(json.loads(self.d.prefs.SETTINGS.read_text())["reactionsSeen"], False, "the shortcuts page leaves it alone")
        self.assertFalse(self.request(self.conn, 52, "settings.reactions", seen="no")["ok"])
        mine = {"tone": 3, "recents": {"emoji:👍": {"c": 2.5, "t": 1789000000000}}}
        self.assertEqual(self.request(self.conn, 53, "settings.emoji", **mine)["result"]["settings"]["emoji"], mine)
        self.assertTrue(self.request(self.conn, 54, "settings.set", settings={"shortcuts": {}})["ok"])
        self.assertEqual(json.loads(self.d.prefs.SETTINGS.read_text())["emoji"], mine, "the shortcuts page leaves it alone")
        for rid, bad in ((55, {"tone": 6, "recents": {}}), (56, {"tone": 1, "recents": {"flag:x": {"c": 1, "t": 1}}}), (57, {"tone": 1})):
            self.assertFalse(self.request(self.conn, rid, "settings.emoji", **bad)["ok"], bad)
        self.daemon.spawn = lambda argv, fallback=None, timeout=None: None   # no sound out of the speakers in a test
        self.assertEqual(self.request(self.conn, 60, "settings.sounds", style="knock")["result"]["settings"]["sounds"]["style"], "knock")
        self.assertFalse(self.request(self.conn, 61, "settings.sounds", style="trumpet")["ok"])
        self.assertEqual(self.request(self.conn, 62, "sounds.another", userId=500)["result"]["settings"]["sounds"]["variants"], {"500": 1})
        self.assertTrue(self.request(self.conn, 63, "settings.set", settings={"shortcuts": {}})["ok"])
        self.assertEqual(json.loads(self.d.prefs.SETTINGS.read_text())["sounds"], {"style": "knock", "variants": {"500": 1}},
                         "the shortcuts page leaves it alone")

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
        self.hints = []

    def notify(self, replaces, title, body, actions, hints):
        self.shown.append((title, body))
        self.hints.append(dict(hints))
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

    def test_a_picture_beside_it_and_buttons_that_act_on_the_chat(self):
        import base64
        tiny = base64.b64encode(bytes((0xFF, 0xD8)) + b"a tiny jpeg").decode()
        photo = self.note(4, "")
        photo["type"]["message"]["content"] = {"@type": "messagePhoto", "caption": {"text": "look", "entities": []}, "photo": {
            "@type": "photo", "minithumbnail": {"@type": "minithumbnail", "width": 40, "height": 30, "data": tiny},
            "sizes": [{"@type": "photoSize", "type": "x", "width": 800, "height": 600, "photo": {
                "@type": "file", "id": 55, "size": 1000, "local": {"@type": "localFile", "path": "", "is_downloading_completed": False}}}]}}
        self.td_event(self.group([photo]))
        self.settle()
        picture = pathlib.Path(self.bus.hints[-1]["image-path"][len("file://"):])
        self.assertEqual((picture.parent, picture.read_bytes()[:2]), (self.root / "notify", bytes((0xFF, 0xD8))),
                         "Telegram's tiny preview of the photo, written out: no download waited for")
        self.td_event(self.group([self.note(5, "no picture for this one")]))
        self.settle()
        self.assertNotIn("image-path", self.bus.hints[-1], "a text message in a chat without a photo")
        for action, kind in (("read", "viewMessages"), ("mute", "setChatNotificationSettings"), ("react", "addMessageReaction")):
            self.td_event(self.group([self.note(6, "again")]))
            self.settle()
            before = self.sent_count(kind)
            self.click(action)
            query = self.next_query(kind, before)
            if kind == "viewMessages":
                self.assertEqual((query["message_ids"], query["force_read"], query["source"]["@type"]), ([60], True, "messageSourceNotification"))
            elif kind == "setChatNotificationSettings":
                self.assertEqual((query["chat_id"], query["notification_settings"]["mute_for"]), (42, 3600))
            else:
                self.assertEqual((query["message_id"], query["reaction_type"]["emoji"]), (60, "👍"))

    def test_each_person_has_a_sound_but_not_in_do_not_disturb_or_a_burst(self):
        def played():
            return [argv for argv, _ in self.spawned if argv and argv[0].endswith("pw-play")]
        self.td_event(self.group([self.note(7, "hi")]))
        self.settle()
        self.wait(lambda: len(played()) == 1)
        wav = pathlib.Path(played()[0][-1])
        self.assertEqual((wav.parent, wav.read_bytes()[:4], played()[0][1:3]), (self.root / "sounds", b"RIFF", ["--media-role", "Notification"]))
        self.assertTrue(wav.name.startswith("drop-"), "Ann's own sound, in the style chosen")
        self.td_event(self.group([self.note(8, "again")]))
        self.settle()
        self.assertEqual(len(played()), 1, "not again for the same person straight away")
        (self.root / "omarchy-notifications.json").write_text(json.dumps({"dnd": True, "version": 1}))
        self.daemon.sound_by_person.clear()
        self.daemon.sound_last = 0.0
        self.td_event(self.group([self.note(9, "while you do not want to be disturbed")]))
        self.settle()
        self.assertEqual(len(played()), 1, "Do Not Disturb keeps it quiet")

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
