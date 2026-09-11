#!/usr/bin/python3
"""python3 tests/state_test.py -- omagram_state against hand-written TDLib objects."""
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "bin"))
import omagram_state as model  # noqa: E402


def chat(cid, title="Chat", kind=None, order="100", pinned=False, unread=0, last=None, lists=("chatListMain",)):
    return {"@type": "chat", "id": cid, "title": title,
            "type": kind or {"@type": "chatTypePrivate", "user_id": cid},
            "unread_count": unread, "unread_mention_count": 0,
            "notification_settings": {"@type": "chatNotificationSettings", "mute_for": 0},
            "positions": [{"@type": "chatPosition", "list": {"@type": name}, "order": order, "is_pinned": pinned}
                          for name in lists],
            "last_read_inbox_message_id": 0, "last_read_outbox_message_id": 0, "last_message": last}


def text_message(mid, cid, text, sender=7, entities=(), outgoing=False, **extra):
    m = {"@type": "message", "id": mid, "chat_id": cid, "date": 1789000000, "edit_date": 0,
         "is_outgoing": outgoing, "is_pinned": False,
         "sender_id": {"@type": "messageSenderUser", "user_id": sender},
         "content": {"@type": "messageText",
                     "text": {"@type": "formattedText", "text": text, "entities": list(entities)}}}
    m.update(extra)
    return m


class Lists(unittest.TestCase):
    def test_folders_come_as_plain_names_in_order(self):
        s = model.State()
        out = s.apply({"@type": "updateChatFolders", "main_chat_list_position": 1, "chat_folders": [
            {"@type": "chatFolderInfo", "id": 3, "name": {"text": {"text": "Work\n  <b>stuff</b>", "entities": []}},
             "icon": {"name": "Work"}},
            {"@type": "chatFolderInfo", "id": 0, "name": {"text": {"text": "bad id"}}},
            {"@type": "chatFolderInfo", "id": 5, "name": "garbage"},
            "junk"]})
        self.assertEqual(out, [{"event": "folders", "mainPosition": 1, "folders": [
            {"id": 3, "name": "Work <b>stuff</b>", "icon": "Work"},
            {"id": 5, "name": "Folder", "icon": ""}]}])
        s.apply({"@type": "updateChatFolders", "chat_folders": "nope", "main_chat_list_position": -4})
        self.assertEqual((s.folders, s.main_position), ([], 0))

    def test_positions_per_list_and_every_chat(self):
        s = model.State()
        s.apply({"@type": "updateNewChat", "chat": chat(1, "In main", order="50")})
        s.apply({"@type": "updateNewChat", "chat": chat(2, "Archived", order="70", lists=("chatListArchive",))})
        s.apply({"@type": "updateNewChat", "chat": chat(3, "Nowhere", order="0")})
        s.apply({"@type": "updateChatPosition", "chat_id": 1, "position": {
            "@type": "chatPosition", "list": {"@type": "chatListFolder", "chat_folder_id": 3},
            "order": "9223372036854775807", "is_pinned": True}})
        view = s.chat_view(1)
        self.assertEqual(view["positions"], {"main": {"order": "50", "pinned": False},
                                             "folder:3": {"order": "9223372036854775807", "pinned": True}})
        self.assertEqual([c["id"] for c in s.all_chats()], [1, 2])


class Formatting(unittest.TestCase):
    def test_entities_are_kept_only_when_they_fit(self):
        text, entities = model.formatted({"text": "hi 👋 bold link", "entities": [
            {"offset": 6, "length": 4, "type": {"@type": "textEntityTypeBold"}},
            {"offset": 11, "length": 4, "type": {"@type": "textEntityTypeTextUrl", "url": "https://x.org"}},
            {"offset": 11, "length": 99, "type": {"@type": "textEntityTypeBold"}},
            {"offset": -1, "length": 2, "type": {"@type": "textEntityTypeBold"}},
            {"offset": 0, "length": 2, "type": {"@type": "textEntityTypeFutureThing"}},
            {"offset": "0", "length": True, "type": {"@type": "textEntityTypeBold"}},
            "junk"]})
        self.assertEqual(text, "hi 👋 bold link")
        # 👋 is two UTF-16 code units, so "bold" starts at 6 and "link" at 11.
        self.assertEqual(entities, [{"type": "bold", "offset": 6, "length": 4},
                                    {"type": "textUrl", "offset": 11, "length": 4, "url": "https://x.org"}])

    def test_hostile_values_do_not_break_anything(self):
        for value in (None, 5, "text", [], {"text": 5}, {"text": "x" * 100000, "entities": "nope"}):
            text, entities = model.formatted(value)
            self.assertLessEqual(len(text), model.TEXT_MAX)
            self.assertEqual(entities, [])

    def test_content_kinds_and_previews(self):
        c = model.content({"@type": "messagePhoto", "caption": {"text": "sunset", "entities": []}})
        self.assertEqual((c["kind"], model.preview_text(c)), ("photo", "Photo, sunset"))
        c = model.content({"@type": "messageSticker", "sticker": {"emoji": "😂"}})
        self.assertEqual((c["kind"], model.preview_text(c)), ("sticker", "😂 Sticker"))
        c = model.content({"@type": "messageDocument", "document": {"file_name": "report.pdf"}, "caption": {"text": ""}})
        self.assertEqual(model.preview_text(c), "report.pdf")
        c = model.content({"@type": "messageVoiceNote", "caption": {"text": ""}})
        self.assertEqual(model.preview_text(c), "Voice message")
        c = model.content({"@type": "messageChatJoinByLink"})
        self.assertEqual((c["kind"], c["type"]), ("service", "messageChatJoinByLink"))
        c = model.content({"@type": "messageSomethingNew"})
        self.assertEqual((c["kind"], model.preview_text(c)), ("unsupported", "Message"))
        c = model.content({"@type": "messageText", "text": {"text": "line one\n\n  line two", "entities": []}})
        self.assertEqual(model.preview_text(c), "line one line two")


class Auth(unittest.TestCase):
    def test_views(self):
        v = model.auth_view
        self.assertEqual(v({"@type": "authorizationStateWaitPhoneNumber"}), {"state": "phone"})
        self.assertEqual(v({"@type": "authorizationStateWaitCode", "code_info": {
            "phone_number": "+380000", "type": {"@type": "authenticationCodeTypeTelegramMessage", "length": 5}}}),
            {"state": "code", "phone": "+380000", "via": "TelegramMessage", "length": 5})
        self.assertEqual(v({"@type": "authorizationStateWaitPassword", "password_hint": "cat"}), {"state": "password", "hint": "cat"})
        self.assertEqual(v({"@type": "authorizationStateWaitOtherDeviceConfirmation", "link": "tg://login?token=x"}),
                         {"state": "qr", "link": "tg://login?token=x"})
        self.assertEqual(v({"@type": "authorizationStateWaitRegistration"}),
                         {"state": "unsupported", "reason": "authorizationStateWaitRegistration"})
        self.assertEqual(v(None), {"state": "unsupported", "reason": ""})


class Chats(unittest.TestCase):
    def setUp(self):
        self.s = model.State()

    def test_new_chats_are_ordered_like_telegram(self):
        self.s.apply({"@type": "updateUser", "user": {"@type": "user", "id": 7, "first_name": "Ann", "last_name": "Lee"}})
        self.s.apply({"@type": "updateNewChat", "chat": chat(1, "Old", order="100")})
        self.s.apply({"@type": "updateNewChat", "chat": chat(2, "Pinned", order="9000", pinned=True)})
        events = self.s.apply({"@type": "updateNewChat", "chat": chat(3, "Archived", order="500", lists=("chatListArchive",),
                                                                      last=text_message(9, 3, "hello"))})
        self.assertEqual(events[0]["chat"]["lastMessage"], {"id": 9, "date": 1789000000, "outgoing": False,
                                                             "senderName": "Ann Lee", "text": "hello"})
        self.assertEqual([c["title"] for c in self.s.chat_list("main")], ["Pinned", "Old"])
        self.assertEqual([c["title"] for c in self.s.chat_list("archive")], ["Archived"])
        self.assertTrue(self.s.chat_view(2)["pinned"])

    def test_position_updates_move_and_remove(self):
        self.s.apply({"@type": "updateNewChat", "chat": chat(1, "A", order="100")})
        self.s.apply({"@type": "updateNewChat", "chat": chat(2, "B", order="200")})
        self.s.apply({"@type": "updateChatLastMessage", "chat_id": 1, "last_message": text_message(5, 1, "new"),
                      "positions": [{"@type": "chatPosition", "list": {"@type": "chatListMain"}, "order": "300"}]})
        self.assertEqual([c["title"] for c in self.s.chat_list()], ["A", "B"])
        self.s.apply({"@type": "updateChatPosition", "chat_id": 2,
                      "position": {"@type": "chatPosition", "list": {"@type": "chatListMain"}, "order": "0"}})
        self.assertEqual([c["title"] for c in self.s.chat_list()], ["A"])

    def test_read_counters_mute_title(self):
        self.s.apply({"@type": "updateNewChat", "chat": chat(1, "A", unread=3)})
        self.assertEqual(self.s.apply({"@type": "updateChatReadInbox", "chat_id": 1, "unread_count": 0,
                                       "last_read_inbox_message_id": 44})[0]["chat"]["unread"], 0)
        self.s.apply({"@type": "updateChatNotificationSettings", "chat_id": 1,
                      "notification_settings": {"mute_for": 2147483647}})
        self.s.apply({"@type": "updateChatTitle", "chat_id": 1, "title": "Renamed"})
        view = self.s.chat_view(1)
        self.assertEqual((view["muted"], view["title"], view["lastReadInbox"]), (True, "Renamed", 44))

    def test_updates_for_unknown_chats_or_garbage_are_ignored(self):
        for update in ({"@type": "updateChatTitle", "chat_id": 99, "title": "x"}, {"@type": "updateChatReadInbox"},
                       {"@type": "updateNope"}, {"@type": "__class__"}, {"@type": 5}, None, "x",
                       {"@type": "updateNewChat", "chat": "nope"}, {"@type": "updateNewMessage", "message": {}}):
            self.assertEqual(self.s.apply(update), [], update)

    def test_group_and_channel_kinds(self):
        self.s.apply({"@type": "updateNewChat", "chat": chat(-1001, "Chan", kind={"@type": "chatTypeSupergroup", "is_channel": True})})
        self.s.apply({"@type": "updateNewChat", "chat": chat(-1002, "Grp", kind={"@type": "chatTypeSupergroup", "is_channel": False})})
        self.s.apply({"@type": "updateNewChat", "chat": chat(-5, "Basic", kind={"@type": "chatTypeBasicGroup"})})
        self.assertEqual([self.s.chat_view(i)["kind"] for i in (-1001, -1002, -5)], ["channel", "group", "group"])


class Messages(unittest.TestCase):
    def setUp(self):
        self.s = model.State()
        self.s.apply({"@type": "updateUser", "user": {"@type": "user", "id": 7, "first_name": "Ann", "last_name": ""}})

    def test_new_message_event(self):
        events = self.s.apply({"@type": "updateNewMessage", "message": text_message(
            10, 1, "hi", reply_to={"@type": "messageReplyToMessage", "chat_id": 1, "message_id": 9},
            sending_state={"@type": "messageSendingStatePending"})})
        m = events[0]["message"]
        self.assertEqual((m["id"], m["senderName"], m["replyTo"], m["sending"], m["content"]["text"]),
                         (10, "Ann", {"chatId": 1, "messageId": 9}, "pending", "hi"))

    def test_int64_ids_as_strings_and_deletes(self):
        m = self.s.message(text_message("123456789012", "-1001234567890", "x"))
        self.assertEqual((m["id"], m["chatId"]), (123456789012, -1001234567890))
        self.assertEqual(self.s.apply({"@type": "updateDeleteMessages", "chat_id": 1, "message_ids": [1, 2], "is_permanent": False}), [])
        self.assertEqual(self.s.apply({"@type": "updateDeleteMessages", "chat_id": 1, "message_ids": [1, "x", 2], "is_permanent": True}),
                         [{"event": "messagesDeleted", "chatId": 1, "messageIds": [1, 2]}])

    def test_send_succeeded_and_failed(self):
        ok = self.s.apply({"@type": "updateMessageSendSucceeded", "old_message_id": 1, "message": text_message(50, 1, "x", outgoing=True)})
        self.assertEqual((ok[0]["event"], ok[0]["oldMessageId"], ok[0]["message"]["id"]), ("messageSent", 1, 50))
        bad = self.s.apply({"@type": "updateMessageSendFailed", "old_message_id": 2, "message": text_message(2, 1, "x"),
                            "error": {"code": 400, "message": "CHAT_WRITE_FORBIDDEN"}})
        self.assertEqual((bad[0]["event"], bad[0]["error"]), ("messageFailed", "CHAT_WRITE_FORBIDDEN"))


ROOT_FILES = "/home/u/.local/share/omagram/files"


def tdfile(fid, path="", done=False, size=1000, downloaded=0, active=False):
    return {"@type": "file", "id": fid, "size": size, "expected_size": size,
            "local": {"@type": "localFile", "path": path, "is_downloading_completed": done,
                      "is_downloading_active": active, "downloaded_size": downloaded},
            "remote": {"@type": "remoteFile", "id": "r", "unique_id": "u"}}


def pack_waveform(samples):
    import base64
    packed = 0
    for i, s in enumerate(samples):
        packed |= (s & 31) << (i * 5)
    return base64.b64encode(packed.to_bytes((len(samples) * 5 + 7) // 8, "little")).decode()


class Media(unittest.TestCase):
    def test_photo_uses_the_largest_size_that_fits(self):
        sizes = [{"@type": "photoSize", "type": t, "width": w, "height": w, "photo": tdfile(i + 1)}
                 for i, (t, w) in enumerate((("s", 90), ("m", 320), ("x", 800), ("y", 1280), ("w", 2560)))]
        c = model.content({"@type": "messagePhoto", "photo": {"sizes": sizes, "minithumbnail":
                           {"@type": "minithumbnail", "width": 40, "height": 40, "data": "AAAA"}},
                           "caption": {"text": "hi"}}, ROOT_FILES)
        self.assertEqual((c["media"]["width"], c["media"]["file"]["id"], c["media"]["mini"]["data"]), (1280, 4, "AAAA"))
        huge = [{"@type": "photoSize", "width": w, "height": w, "photo": tdfile(w)} for w in (4000, 2560)]
        self.assertEqual(model.best_photo_size(huge)[0], 2560)
        self.assertIsNone(model.best_photo_size([{"@type": "photoSize", "width": 0, "height": 5, "photo": tdfile(1)}, "x"]))

    def test_paths_are_exposed_only_inside_the_files_directory_and_only_when_complete(self):
        inside = ROOT_FILES + "/photos/1.jpg"
        self.assertEqual(model.file_view(tdfile(1, inside, done=True), ROOT_FILES)["path"], inside)
        self.assertEqual(model.file_view(tdfile(1, inside, done=False), ROOT_FILES)["path"], "")
        for bad in ("/etc/passwd", ROOT_FILES + "/../../../.ssh/id_ed25519", ROOT_FILES + "x/a.jpg",
                    "photos/1.jpg", ROOT_FILES + "/a\nb.jpg", ROOT_FILES + "//a.jpg", 5):
            self.assertEqual(model.file_view(tdfile(1, bad, done=True), ROOT_FILES)["path"], "", bad)
        self.assertEqual(model.file_view(tdfile(1, inside, done=True), "")["path"], "")
        self.assertIsNone(model.file_view({"@type": "file", "id": 0}, ROOT_FILES))

    def test_stickers_beside_the_database_are_shown_but_the_database_never_is(self):
        data = "/home/u/.local/share/omagram"
        roots = (data + "/files", data + "/database/stickers", data + "/database/thumbnails")
        for ok in (data + "/database/stickers/1137162165791228153.tgs", data + "/database/thumbnails/5.jpg",
                   data + "/files/photos/1.jpg"):
            self.assertEqual(model.local_path(ok, roots), ok)
        for bad in (data + "/database/td.binlog", data + "/database/db.sqlite", data + "/database/temp/x",
                    data + "/database/stickers/../td.binlog", data + "/database/stickersx/a.webp",
                    data + "/database/stickers", "/etc/passwd"):
            self.assertEqual(model.local_path(bad, roots), "", bad)
        self.assertEqual(model.local_path(data + "/files/a.jpg", ("relative/root", 5, None)), "")

    def test_stickers_voice_video_notes_files(self):
        for fmt, name in (("stickerFormatTgs", "tgs"), ("stickerFormatWebm", "webm"), ("stickerFormatWebp", "webp"), ("x", "unknown")):
            c = model.content({"@type": "messageSticker", "sticker": {"@type": "sticker", "width": 512, "height": 512,
                               "emoji": "😂", "format": {"@type": fmt}, "sticker": tdfile(3)}}, ROOT_FILES)
            self.assertEqual((c["media"]["format"], c["media"]["emoji"], c["emoji"]), (name, "😂", "😂"))
        samples = [i % 32 for i in range(40)]
        c = model.content({"@type": "messageVoiceNote", "is_listened": True, "caption": {"text": ""},
                           "voice_note": {"@type": "voiceNote", "duration": 7, "waveform": pack_waveform(samples),
                                          "mime_type": "audio/ogg", "voice": tdfile(9)}}, ROOT_FILES)
        self.assertEqual((c["media"]["duration"], c["media"]["waveform"], c["media"]["listened"]), (7, samples, True))
        c = model.content({"@type": "messageVideoNote", "video_note": {"@type": "videoNote", "duration": 12, "length": 384,
                           "video": tdfile(10)}}, ROOT_FILES)
        self.assertEqual((c["kind"], c["media"]["length"]), ("videoNote", 384))
        c = model.content({"@type": "messageDocument", "caption": {"text": ""}, "document": {
            "@type": "document", "file_name": "report.pdf", "mime_type": "application/pdf", "document": tdfile(11, size=5000)}}, ROOT_FILES)
        self.assertEqual((c["media"]["fileName"], c["media"]["file"]["size"]), ("report.pdf", 5000))
        self.assertNotIn("media", model.content({"@type": "messagePhoto", "photo": {"sizes": []}}, ROOT_FILES))

    def test_waveform_is_bucketed_and_bounded(self):
        long = pack_waveform([31 if i % 10 == 0 else 1 for i in range(100)])
        bars = model.waveform(long)
        self.assertEqual(len(bars), model.WAVEFORM_BARS)
        self.assertTrue(all(0 <= b <= 31 for b in bars))
        for bad in ("!!!", "A" * 1000, 5, ""):
            self.assertEqual(model.waveform(bad), [], bad)
        self.assertIsNone(model.minithumbnail({"@type": "minithumbnail", "data": "A" * (model.MINI_MAX + 1)}))

    def test_file_progress_is_throttled(self):
        s = model.State(ROOT_FILES)
        size = 10 * 1024 * 1024
        first = s.apply({"@type": "updateFile", "file": tdfile(5, size=size, downloaded=0, active=True)})
        self.assertEqual(first[0]["file"]["id"], 5)
        self.assertEqual(s.apply({"@type": "updateFile", "file": tdfile(5, size=size, downloaded=100_000, active=True)}), [])
        self.assertEqual(len(s.apply({"@type": "updateFile", "file": tdfile(5, size=size, downloaded=size // 10, active=True)})), 1)
        done = s.apply({"@type": "updateFile", "file": tdfile(5, ROOT_FILES + "/videos/5.mp4", done=True, size=size, downloaded=size)})
        self.assertEqual(done[0]["file"]["path"], ROOT_FILES + "/videos/5.mp4")
        self.assertEqual(s.apply({"@type": "updateFile", "file": "junk"}), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
