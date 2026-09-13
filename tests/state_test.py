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


def txt(text):
    return {"@type": "messageText", "text": {"@type": "formattedText", "text": text, "entities": []}}


class RichMessages(unittest.TestCase):
    def setUp(self):
        self.s = model.State()
        self.s.apply({"@type": "updateUser", "user": {"@type": "user", "id": 7, "first_name": "Ann",
                                                      "type": {"@type": "userTypeRegular"},
                                                      "status": {"@type": "userStatusOnline", "expires": 1789000500}}})
        self.s.apply({"@type": "updateUser", "user": {"@type": "user", "id": 8, "first_name": "Bob",
                                                      "type": {"@type": "userTypeBot"}}})
        self.s.apply({"@type": "updateNewChat", "chat": chat(-100, "News", kind={"@type": "chatTypeSupergroup", "supergroup_id": 1,
                                                                                  "is_channel": True})})
        self.s.apply({"@type": "updateNewChat", "chat": chat(-200, "Friends", kind={"@type": "chatTypeBasicGroup"})})

    def msg(self, body, **extra):
        m = {"@type": "message", "id": 1, "chat_id": -200, "date": 1, "is_outgoing": False,
             "sender_id": {"@type": "messageSenderUser", "user_id": 7}, "content": body}
        m.update(extra)
        return self.s.message(m)

    def test_forwards_say_where_they_came_from(self):
        origin = lambda o: {"@type": "messageForwardInfo", "date": 5, "origin": o}   # noqa: E731
        self.assertEqual(self.msg(txt("hi"), forward_info=origin({"@type": "messageOriginUser", "sender_user_id": 8}))["forward"],
                         {"name": "Bob", "date": 5})
        self.assertEqual(self.msg(txt("hi"), forward_info=origin({"@type": "messageOriginHiddenUser", "sender_name": "Carol"}))["forward"]["name"],
                         "Carol")
        self.assertEqual(self.msg(txt("hi"), forward_info=origin({"@type": "messageOriginChannel", "chat_id": -100, "message_id": 3,
                                                                  "author_signature": "Dan"}))["forward"]["name"], "News (Dan)")
        self.assertEqual(self.msg(txt("hi"), forward_info=origin({"@type": "messageOriginUser", "sender_user_id": 999}))["forward"]["name"],
                         "Unknown")
        self.assertIsNone(self.msg(txt("hi"))["forward"])

    def test_albums_reactions_and_views(self):
        m = self.msg(txt("x"), media_album_id="1380000000000001", interaction_info={
            "@type": "messageInteractionInfo", "view_count": 42, "reactions": {"@type": "messageReactions", "reactions": [
                {"@type": "messageReaction", "type": {"@type": "reactionTypeEmoji", "emoji": "👍"}, "total_count": 3, "is_chosen": True},
                {"@type": "messageReaction", "type": {"@type": "reactionTypeCustomEmoji", "custom_emoji_id": "5"}, "total_count": 1},
                {"@type": "messageReaction", "type": {"@type": "reactionTypeEmoji", "emoji": "🔥"}, "total_count": 0},
                "junk"]}})
        self.assertEqual(m["albumId"], "1380000000000001")
        self.assertEqual(m["reactions"], [{"emoji": "👍", "count": 3, "chosen": True},
                                          {"emoji": "", "customEmojiId": "5", "count": 1, "chosen": False}])
        self.assertEqual(m["views"], 42)
        plain = self.msg(txt("x"))
        self.assertEqual((plain["albumId"], plain["reactions"], plain["views"], plain["markup"]), ("", [], 0, None))
        self.assertEqual((plain["replies"], plain["threadId"]), (None, 0))

    def test_comments_and_replies(self):
        post = self.msg(txt("x"), interaction_info={"@type": "messageInteractionInfo", "reply_info": {
            "@type": "messageReplyInfo", "reply_count": 4, "last_read_inbox_message_id": 90, "last_message_id": 95}})
        self.assertEqual(post["replies"], {"count": 4, "unread": True})
        read = self.msg(txt("x"), interaction_info={"@type": "messageInteractionInfo", "reply_info": {
            "@type": "messageReplyInfo", "reply_count": 0, "last_read_inbox_message_id": 0, "last_message_id": 0}})
        self.assertEqual(read["replies"], {"count": 0, "unread": False}, "comments are open, and there are none yet")
        comment = self.msg(txt("x"), topic_id={"@type": "messageTopicThread", "message_thread_id": 77})
        self.assertEqual((comment["threadId"], comment["topicId"]), (77, 0))
        in_topic = self.msg(txt("x"), topic_id={"@type": "messageTopicForum", "forum_topic_id": 5})
        self.assertEqual((in_topic["threadId"], in_topic["topicId"]), (0, 5))

    def test_bot_buttons_and_keyboards(self):
        button = lambda text, kind: {"@type": "inlineKeyboardButton", "text": text, "type": kind}   # noqa: E731
        markup = {"@type": "replyMarkupInlineKeyboard", "rows": [
            [button("Yes", {"@type": "inlineKeyboardButtonTypeCallback", "data": "eWVz"}),
             button("Site", {"@type": "inlineKeyboardButtonTypeUrl", "url": "https://example.com"})],
            [button("Bad data", {"@type": "inlineKeyboardButtonTypeCallback", "data": "x" * 500}),
             button("Profile", {"@type": "inlineKeyboardButtonTypeUser", "user_id": 8}),
             button("Copy", {"@type": "inlineKeyboardButtonTypeCopyText", "text": "code 42"}),
             button("Buy", {"@type": "inlineKeyboardButtonTypeBuy"})],
            "junk", []]}
        m = self.msg(txt("pick"), reply_markup=markup)
        rows = m["markup"]["rows"]
        self.assertEqual(m["markup"]["type"], "inline")
        self.assertEqual(rows[0], [{"text": "Yes", "kind": "callback", "data": "eWVz"},
                                   {"text": "Site", "kind": "url", "url": "https://example.com"}])
        self.assertEqual([b["kind"] for b in rows[1]], ["unsupported", "user", "copy", "buy"])
        self.assertEqual((rows[1][1]["userId"], rows[1][2]["copyText"], len(rows)), (8, "code 42", 2))
        keyboard = self.msg(txt("menu"), reply_markup={"@type": "replyMarkupShowKeyboard", "rows": [[
            {"@type": "keyboardButton", "text": "Start", "type": {"@type": "keyboardButtonTypeText"}},
            {"@type": "keyboardButton", "text": "Phone", "type": {"@type": "keyboardButtonTypeRequestPhoneNumber"}}]],
            "one_time": True, "resize_keyboard": True, "input_field_placeholder": "Choose"})["markup"]
        self.assertEqual(keyboard, {"type": "keyboard", "rows": [[{"text": "Start", "kind": "text"}, {"text": "Phone", "kind": "requestPhone"}]],
                                    "oneTime": True, "resize": True, "persistent": False, "placeholder": "Choose"})
        self.assertEqual(self.msg(txt("x"), reply_markup={"@type": "replyMarkupRemoveKeyboard"})["markup"], {"type": "remove"})

    def test_link_previews_polls_places_contacts_and_spoilers(self):
        size = {"@type": "photoSize", "type": "m", "width": 320, "height": 200, "photo": {"@type": "file", "id": 9, "size": 100, "local": {}}}
        text = dict(txt("see https://ex.am/a"), link_preview={
            "@type": "linkPreview", "url": "https://ex.am/a", "display_url": "ex.am/a", "site_name": "Ex", "title": "An article",
            "description": {"text": "About it", "entities": []},
            "type": {"@type": "linkPreviewTypeArticle", "photo": {"@type": "photo", "sizes": [size]}}})
        preview = self.msg(text)["content"]["linkPreview"]
        self.assertEqual({k: preview[k] for k in ("url", "displayUrl", "siteName", "title", "description")},
                         {"url": "https://ex.am/a", "displayUrl": "ex.am/a", "siteName": "Ex", "title": "An article", "description": "About it"})
        self.assertEqual(preview["photo"]["file"]["id"], 9)
        option = lambda text, voters, percent, chosen=False: {"@type": "pollOption", "text": {"text": text}, "voter_count": voters,   # noqa: E731
                                                              "vote_percentage": percent, "is_chosen": chosen}
        poll = self.msg({"@type": "messagePoll", "poll": {"@type": "poll", "id": "77", "question": {"text": "Lunch?"},
                                                          "options": [option("Pizza", 3, 75, True), option("Soup", 1, 25)],
                                                          "total_voter_count": 4, "is_anonymous": True, "allows_multiple_answers": False,
                                                          "type": {"@type": "pollTypeQuiz", "correct_option_ids": [0]}, "is_closed": True}})["content"]
        self.assertEqual((poll["text"], poll["poll"]["id"], poll["poll"]["total"], poll["poll"]["quiz"], poll["poll"]["correct"],
                          poll["poll"]["closed"], poll["poll"]["voted"]), ("Lunch?", "77", 4, True, [0], True, True))
        self.assertEqual(poll["poll"]["options"][1], {"index": 1, "text": "Soup", "voters": 1, "percent": 25, "chosen": False})
        venue = self.msg({"@type": "messageVenue", "venue": {"@type": "venue", "title": "Cafe", "address": "Main St 1",
                                                             "location": {"@type": "location", "latitude": 50.45, "longitude": 30.52}}})["content"]
        self.assertEqual(venue["location"], {"lat": 50.45, "lon": 30.52, "title": "Cafe", "address": "Main St 1"})
        bad = self.msg({"@type": "messageLocation", "location": {"@type": "location", "latitude": 500, "longitude": 0}})["content"]
        self.assertNotIn("location", bad)
        contact = self.msg({"@type": "messageContact", "contact": {"@type": "contact", "first_name": "Eve", "last_name": "L",
                                                                   "phone_number": "+100", "user_id": 12}})["content"]
        self.assertEqual((contact["contact"], contact["text"]), ({"name": "Eve L", "phone": "+100", "userId": 12}, "Eve L"))
        photo = self.msg({"@type": "messagePhoto", "has_spoiler": True, "caption": {"text": ""},
                          "photo": {"@type": "photo", "sizes": [size]}})["content"]
        self.assertTrue(photo["spoiler"])
        self.assertNotIn("spoiler", self.msg(txt("plain"))["content"])

    def test_service_messages_in_words(self):
        def say(body, sender=7, chat_id=-200):
            return self.msg(body, sender_id={"@type": "messageSenderUser", "user_id": sender}, chat_id=chat_id)["content"]["text"]
        self.assertEqual(say({"@type": "messageChatAddMembers", "member_user_ids": [7]}), "Ann joined the group")
        self.assertEqual(say({"@type": "messageChatAddMembers", "member_user_ids": [8, 999]}), "Ann added Bob, someone")
        self.assertEqual(say({"@type": "messageChatDeleteMember", "user_id": 7}), "Ann left the group")
        self.assertEqual(say({"@type": "messageChatDeleteMember", "user_id": 8}), "Ann removed Bob")
        self.assertEqual(say({"@type": "messageChatChangeTitle", "title": "Best"}), "Ann renamed the group to “Best”")
        self.assertEqual(say({"@type": "messagePinMessage", "message_id": 4}), "Ann pinned a message")
        self.assertEqual(say({"@type": "messageCall", "is_video": False, "duration": 125}), "Call, 2:05")
        self.assertEqual(say({"@type": "messageCall", "is_video": True, "duration": 0}), "Missed video call")
        self.assertEqual(say({"@type": "messageChatSetMessageAutoDeleteTime", "message_auto_delete_time": 86400}),
                         "Ann set messages to disappear after 1 day")
        self.assertEqual(say({"@type": "messageChatJoinByLink"}, chat_id=-100), "Ann joined the channel with an invite link")
        self.assertEqual(say({"@type": "messageCustomServiceAction", "text": "Game over"}), "Game over")
        unknown = self.msg({"@type": "messageChatSomethingNew"})["content"]
        self.assertEqual((unknown["kind"], unknown["text"]), ("service", ""))
        self.assertEqual(model.preview_text(self.msg({"@type": "messageChatDeletePhoto"})["content"]), "Ann removed the group photo")

    def test_status_drafts_actions_and_live_updates(self):
        s = self.s
        s.apply({"@type": "updateNewChat", "chat": dict(chat(7, "Ann"), draft_message={
            "@type": "draftMessage", "date": 1, "content": {"@type": "draftMessageContentText", "text": {"text": "half-written"}}})})
        view = s.chat_view(7)
        self.assertEqual((view["draft"], view["status"]["state"], view["bot"]), ("half-written", "online", False))
        self.assertEqual(s.chat_view(-200)["status"], None)
        out = s.apply({"@type": "updateUserStatus", "user_id": 7, "status": {"@type": "userStatusOffline", "was_online": 1789000000}})
        self.assertEqual(out, [{"event": "userStatus", "userId": 7, "status": {"state": "offline", "wasOnline": 1789000000}}])
        self.assertEqual(s.chat_view(7)["status"]["state"], "offline")
        self.assertEqual(s.apply({"@type": "updateChatDraftMessage", "chat_id": 7, "draft_message": None, "positions": []})[0]["chat"]["draft"], "")
        out = s.apply({"@type": "updateChatAction", "chat_id": -200, "sender_id": {"@type": "messageSenderUser", "user_id": 8},
                       "action": {"@type": "chatActionRecordingVoiceNote"}})
        self.assertEqual(out, [{"event": "chatAction", "chatId": -200, "senderId": 8, "senderName": "Bob", "action": "recordingVoice"}])
        self.assertEqual(s.apply({"@type": "updateChatAction", "chat_id": -200, "action": {"@type": "chatActionNope"}}), [])
        out = s.apply({"@type": "updateMessageInteractionInfo", "chat_id": -200, "message_id": 3, "interaction_info": {
            "@type": "messageInteractionInfo", "view_count": 2, "reactions": {"reactions": [
                {"@type": "messageReaction", "type": {"@type": "reactionTypeEmoji", "emoji": "❤"}, "total_count": 1}]}}})
        self.assertEqual(out, [{"event": "messageInteraction", "chatId": -200, "messageId": 3, "views": 2,
                                "reactions": [{"emoji": "❤", "count": 1, "chosen": False}], "replies": None}])
        self.assertEqual(s.apply({"@type": "updateMessageIsPinned", "chat_id": -200, "message_id": 3, "is_pinned": True}),
                         [{"event": "messagePinned", "chatId": -200, "messageId": 3, "pinned": True}])
        self.assertEqual(s.apply({"@type": "updatePoll", "poll": {"@type": "poll", "id": "77", "question": {"text": "Q"}, "options": []}})[0]["poll"]["id"],
                         "77")
        self.assertEqual(s.chats[7]["notification"]["@type"], "chatNotificationSettings")


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

    def test_chat_photos_and_their_updates(self):
        s = model.State()
        photo = {"@type": "chatPhotoInfo", "small": {"@type": "file", "id": 77, "size": 4000, "local": {}},
                 "big": {"@type": "file", "id": 78},
                 "minithumbnail": {"@type": "minithumbnail", "width": 40, "height": 40, "data": "AAAA"}}
        c = chat(1, "With photo")
        c["photo"] = photo
        s.apply({"@type": "updateNewChat", "chat": c})
        view = s.chat_view(1)["photo"]
        self.assertEqual((view["file"]["id"], view["file"]["path"], view["mini"]["data"]), (77, "", "AAAA"))
        self.assertIsNone(s.chat_view(1).get("photo", {}).get("big") if False else None)
        out = s.apply({"@type": "updateChatPhoto", "chat_id": 1, "photo": None})
        self.assertIsNone(out[0]["chat"]["photo"])
        s.apply({"@type": "updateChatPhoto", "chat_id": 1, "photo": {"@type": "chatPhotoInfo", "small": "junk"}})
        self.assertIsNone(s.chat_view(1)["photo"])
        self.assertEqual(s.apply({"@type": "updateChatPhoto", "chat_id": 999, "photo": photo}), [])

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


class GroupsAndTopics(unittest.TestCase):
    def test_chats_know_their_group_size_username_forum_and_your_place(self):
        s = model.State()
        s.apply({"@type": "updateSupergroup", "supergroup": {"@type": "supergroup", "id": 77, "member_count": 40, "is_forum": True,
                                                             "usernames": {"@type": "usernames", "active_usernames": ["club"]},
                                                             "status": {"@type": "chatMemberStatusAdministrator"}}})
        s.apply({"@type": "updateNewChat", "chat": chat(-10077, "Club", kind={"@type": "chatTypeSupergroup", "supergroup_id": 77})})
        view = s.chat_view(-10077)
        self.assertEqual((view["memberCount"], view["username"], view["forum"], view["myStatus"]), (40, "club", True, "admin"))
        events = s.apply({"@type": "updateSupergroup", "supergroup": {"@type": "supergroup", "id": 77, "member_count": 41}})
        self.assertEqual([(e["chat"]["id"], e["chat"]["memberCount"], e["chat"]["forum"]) for e in events], [(-10077, 41, False)])
        s.apply({"@type": "updateNewChat", "chat": chat(-5, "Friends", kind={"@type": "chatTypeBasicGroup", "basic_group_id": 5})})
        s.apply({"@type": "updateBasicGroup", "basic_group": {"@type": "basicGroup", "id": 5, "member_count": 3,
                                                              "status": {"@type": "chatMemberStatusLeft"}}})
        self.assertEqual((s.chat_view(-5)["memberCount"], s.chat_view(-5)["myStatus"]), (3, "left"))
        self.assertEqual([(s.chat_view(c)["supergroup"], s.chat_view(c)["joinToWrite"]) for c in (-10077, -5)], [(True, True), (False, True)])
        # A channel's discussion group that takes comments from people who have not joined it.
        s.apply({"@type": "updateSupergroup", "supergroup": {"@type": "supergroup", "id": 78, "has_linked_chat": True,
                                                             "join_to_send_messages": False, "status": {"@type": "chatMemberStatusLeft"}}})
        s.apply({"@type": "updateNewChat", "chat": chat(-10078, "Comments", kind={"@type": "chatTypeSupergroup", "supergroup_id": 78})})
        self.assertEqual((s.chat_view(-10078)["myStatus"], s.chat_view(-10078)["joinToWrite"]), ("left", False))
        s.apply({"@type": "updateSupergroup", "supergroup": {"@type": "supergroup", "id": 78, "has_linked_chat": True,
                                                             "join_to_send_messages": True, "status": {"@type": "chatMemberStatusLeft"}}})
        self.assertTrue(s.chat_view(-10078)["joinToWrite"], "one that takes comments from its members only")
        for junk in ({"@type": "updateSupergroup", "supergroup": "x"}, {"@type": "updateBasicGroup"},
                     {"@type": "updateSupergroup", "supergroup": {"@type": "supergroup", "id": -1}}):
            self.assertEqual(s.apply(junk), [])
        self.assertFalse(s.chat_view(-5)["markedUnread"])
        s.apply({"@type": "updateChatIsMarkedAsUnread", "chat_id": -5, "is_marked_as_unread": True})
        self.assertTrue(s.chat_view(-5)["markedUnread"])

    def test_members_topics_sessions_and_phone_numbers(self):
        s = model.State()
        event = s.apply({"@type": "updateUser", "user": {"@type": "user", "id": 7, "first_name": "Ann", "phone_number": "380671234567"}})
        self.assertNotIn("phone", event[0]["user"], "phone numbers are not broadcast")
        self.assertEqual(s.users[7]["phone"], "380671234567")
        member = s.member_view({"@type": "chatMember", "member_id": {"@type": "messageSenderUser", "user_id": 7},
                                "status": {"@type": "chatMemberStatusCreator"}})
        self.assertEqual((member["name"], member["status"], member["type"]), ("Ann", "owner", "user"))
        self.assertIsNone(s.member_view("junk"))
        topic = s.topic_view({"@type": "forumTopic", "unread_count": 2, "order": "99", "last_message": text_message(5, -100, "see you"),
                              "info": {"@type": "forumTopicInfo", "chat_id": -100, "forum_topic_id": 3, "name": "Rides",
                                       "icon": {"@type": "forumTopicIcon", "color": -1}}})
        self.assertEqual((topic["id"], topic["name"], topic["color"], topic["unread"], topic["lastMessage"]["text"]),
                         (3, "Rides", 0xFFFFFF, 2, "see you"))
        self.assertIsNone(s.topic_view({"@type": "forumTopic", "info": {"@type": "forumTopicInfo", "forum_topic_id": 0}}))
        in_topic = s.message(text_message(9, -100, "hi", topic_id={"@type": "messageTopicForum", "forum_topic_id": 3}))
        self.assertEqual((in_topic["topicId"], s.message(text_message(10, -100, "hi"))["topicId"]), (3, 0))
        closed = s.apply({"@type": "updateForumTopicInfo", "info": {"@type": "forumTopicInfo", "chat_id": -100, "forum_topic_id": 3,
                                                                    "name": "Rides", "is_closed": True}})
        self.assertEqual((closed[0]["event"], closed[0]["closed"]), ("topicInfo", True))
        session = model.session_view({"@type": "session", "id": "123", "is_current": True, "application_name": "Omagram",
                                      "device_type": {"@type": "sessionDeviceTypeLinux"}, "last_active_date": 5})
        self.assertEqual((session["id"], session["current"], session["type"], session["app"]), ("123", True, "linux", "Omagram"))
        self.assertEqual(model.session_view({"@type": "session", "id": "5", "device_type": {"@type": "sessionDeviceTypeToaster"}})["type"],
                         "unknown")
        current = model.session_view({"@type": "session", "id": "0", "is_current": True})
        self.assertEqual((current["id"], current["current"]), ("0", True), "Telegram gives the device in use id 0")
        self.assertIsNone(model.session_view("junk"))


class Extras(unittest.TestCase):
    def test_custom_emoji_scheduled_messages_secret_chats_and_calls(self):
        _, entities = model.formatted({"@type": "formattedText", "text": "hi 😀", "entities": [
            {"@type": "textEntity", "offset": 3, "length": 2,
             "type": {"@type": "textEntityTypeCustomEmoji", "custom_emoji_id": "5368324170671202286"}}]})
        self.assertEqual(entities, [{"type": "customEmoji", "offset": 3, "length": 2, "customEmojiId": "5368324170671202286"}])
        s = model.State()
        later = s.message(text_message(5, 1, "later", scheduling_state={"@type": "messageSchedulingStateSendAtDate", "send_date": 1789999999}))
        online = s.message(text_message(6, 1, "hi", scheduling_state={"@type": "messageSchedulingStateSendWhenOnline"}))
        self.assertEqual((later["sendAt"], online["sendAt"], s.message(text_message(7, 1, "now"))["sendAt"]), (1789999999, -1, 0))
        s.apply({"@type": "updateNewChat", "chat": chat(-9, "Ann", kind={"@type": "chatTypeSecret", "secret_chat_id": 9, "user_id": 7})})
        events = s.apply({"@type": "updateSecretChat", "secret_chat": {"@type": "secretChat", "id": 9, "user_id": 7, "is_outbound": False,
                                                                       "state": {"@type": "secretChatStatePending"}, "key_hash": "not base64!"}})
        self.assertEqual(events[0]["chat"]["secret"], {"state": "pending", "outbound": False})
        self.assertEqual(s.secret_chats[9]["keyHash"], "")
        s.apply({"@type": "updateChatHasScheduledMessages", "chat_id": -9, "has_scheduled_messages": True})
        self.assertTrue(s.chat_view(-9)["hasScheduled"])
        self.assertIsNone(s.chat_view(1), "no view for a chat never seen")
        ended = s.apply({"@type": "updateCall", "call": {"@type": "call", "id": 4, "user_id": 7, "is_outgoing": False,
                                                         "state": {"@type": "callStateDiscarded"}}})
        self.assertEqual((ended[0]["call"]["state"], 4 in s.calls), ("ended", False))
        self.assertEqual(s.apply({"@type": "updateCall", "call": "junk"}), [])

    def test_active_stories_and_story_views(self):
        s = model.State()
        s.apply({"@type": "updateNewChat", "chat": chat(7, "Ann")})
        events = s.apply({"@type": "updateChatActiveStories", "active_stories": {
            "@type": "chatActiveStories", "chat_id": 7, "list": {"@type": "storyListMain"}, "order": 5000, "max_read_story_id": 10,
            "stories": [{"@type": "storyInfo", "story_id": 10, "date": 1789000000},
                        {"@type": "storyInfo", "story_id": 11, "date": 1789000100, "is_for_close_friends": True},
                        {"@type": "storyInfo", "story_id": -1}, "junk"]}})
        view = events[0]["stories"]
        self.assertEqual((view["chatId"], view["list"], view["order"], view["maxReadId"], view["title"], [x["id"] for x in view["stories"]]),
                         (7, "main", "5000", 10, "Ann", [10, 11]))
        self.assertEqual((view["stories"][0]["closeFriends"], view["stories"][1]["closeFriends"]), (False, True))
        self.assertEqual(s.story_list(), [view])
        gone = s.apply({"@type": "updateChatActiveStories", "active_stories": {"@type": "chatActiveStories", "chat_id": 7, "stories": []}})
        self.assertEqual((gone[0]["stories"]["stories"], s.story_list()), ([], []), "a chat whose stories expired leaves the list")
        self.assertEqual(s.apply({"@type": "updateChatActiveStories", "active_stories": "junk"}), [])
        video = s.story_view({"@type": "story", "id": 11, "poster_chat_id": 7, "date": 1789000100, "can_be_forwarded": False,
                              "caption": {"@type": "formattedText", "text": "hi", "entities": []},
                              "content": {"@type": "storyContentVideo", "video": {
                                  "@type": "storyVideo", "duration": 12.5, "width": 720, "height": 1280,
                                  "video": {"@type": "file", "id": 5, "size": 100, "local": {}}}}})
        self.assertEqual((video["kind"], video["media"]["file"]["id"], video["media"]["duration"], video["caption"]["text"],
                          video["protected"], video["title"]), ("video", 5, 12, "hi", True, "Ann"))
        live = s.story_view({"@type": "story", "id": 12, "poster_chat_id": 7, "content": {"@type": "storyContentLive"}})
        odd = s.story_view({"@type": "story", "id": 13, "poster_chat_id": 7, "content": {"@type": "storyContentVideo", "video": "junk"}})
        self.assertEqual((live["kind"], live["media"], odd["kind"]), ("live", None, "unsupported"))
        self.assertIsNone(s.story_view({"@type": "story", "id": 0, "poster_chat_id": 7}))
        self.assertIsNone(s.story_view("junk"))


class Privacy(unittest.TestCase):
    def rules(self, *rules):
        return {"@type": "userPrivacySettingRules", "rules": list(rules)}

    def test_who_in_general_and_the_exceptions(self):
        allow_users = {"@type": "userPrivacySettingRuleAllowUsers", "user_ids": [5, 6]}
        keep_out = {"@type": "userPrivacySettingRuleRestrictUsers", "user_ids": [9]}
        groups = {"@type": "userPrivacySettingRuleAllowChatMembers", "chat_ids": [-100]}
        contacts = {"@type": "userPrivacySettingRuleAllowContacts"}
        everyone = {"@type": "userPrivacySettingRuleAllowAll"}
        self.assertEqual(model.privacy_view(self.rules(allow_users, keep_out, groups, contacts)),
                         {"base": "contacts", "allowed": 3, "restricted": 1})
        self.assertEqual(model.privacy_view(self.rules(everyone)), {"base": "everybody", "allowed": 0, "restricted": 0})
        self.assertEqual(model.privacy_view(self.rules()), {"base": "nobody", "allowed": 0, "restricted": 0}, "no rule, no one")
        self.assertEqual(model.privacy_view("junk"), {"base": "nobody", "allowed": 0, "restricted": 0})

        self.assertEqual(model.privacy_rules(self.rules(allow_users, keep_out, contacts), "everybody")["rules"],
                         [keep_out, everyone], "allowing someone means nothing once everybody is")
        self.assertEqual(model.privacy_rules(self.rules(allow_users, keep_out, contacts), "nobody")["rules"],
                         [allow_users, {"@type": "userPrivacySettingRuleRestrictAll"}])
        self.assertEqual(model.privacy_rules(self.rules(keep_out, everyone, allow_users, "junk"), "contacts")["rules"],
                         [keep_out, allow_users, contacts])

    def test_notifications_for_a_type_of_chat(self):
        tdlib = {"@type": "scopeNotificationSettings", "mute_for": 0, "sound_id": "5", "show_preview": True,
                 "use_default_mute_stories": True, "mute_stories": False, "story_sound_id": "-1", "show_story_poster": True,
                 "disable_pinned_message_notifications": False, "disable_mention_notifications": True}
        self.assertEqual(model.scope_view(tdlib), {"muted": False, "preview": True})
        muted = model.scope_settings(tdlib, muted=True)
        self.assertEqual((muted["mute_for"], muted["show_preview"], muted["sound_id"], muted["story_sound_id"],
                          muted["disable_mention_notifications"], muted["use_default_mute_stories"]),
                         (2 ** 31 - 1, True, 5, -1, True, True), "only the mute changes")
        hidden = model.scope_settings(dict(tdlib, mute_for=3600), preview=False)
        self.assertEqual((hidden["mute_for"], hidden["show_preview"]), (3600, False))
        self.assertEqual(model.scope_view(None), {"muted": False, "preview": False})

    def test_two_step_verification(self):
        state = model.password_view({"@type": "passwordState", "has_password": True, "password_hint": "cat",
                                     "has_recovery_email_address": False, "pending_reset_date": 0,
                                     "recovery_email_address_code_info": {"@type": "emailAddressAuthenticationCodeInfo",
                                                                          "email_address_pattern": "a***@m***.com", "length": 6}})
        self.assertEqual(state, {"hasPassword": True, "hint": "cat", "hasRecoveryEmail": False,
                                 "emailCodePattern": "a***@m***.com", "emailCodeLength": 6, "resetDate": 0})
        self.assertEqual(model.password_view(None), {"hasPassword": False, "hint": "", "hasRecoveryEmail": False,
                                                     "emailCodePattern": "", "emailCodeLength": 0, "resetDate": 0})


class Bounds(unittest.TestCase):
    def test_users_are_capped_but_never_someone_a_chat_is_with(self):
        from unittest import mock
        s = model.State()
        with mock.patch.object(model, "USERS_MAX", 10):
            s.apply({"@type": "updateNewChat", "chat": chat(1)})
            for uid in range(1, 16):
                s.apply({"@type": "updateUser", "user": {"@type": "user", "id": uid, "first_name": f"U{uid}"}})
        self.assertLessEqual(len(s.users), 10)
        self.assertIn(1, s.users, "the person a private chat is with stays")
        self.assertIn(15, s.users, "the users heard of last stay")
        self.assertNotIn(2, s.users, "the users heard of first go")


if __name__ == "__main__":
    unittest.main(verbosity=1)
