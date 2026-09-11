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


if __name__ == "__main__":
    unittest.main(verbosity=1)
