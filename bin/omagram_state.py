"""omagram_state -- the account as Omagram's UI sees it: chats, users and messages.

Pure: it takes TDLib objects (already parsed JSON) and returns plain dicts and events, so it
is tested without TDLib, a socket or a network. Everything TDLib delivers is network data and
is read that way: fields are checked before use, strings are capped, and nothing here is ever
meant to be rendered as markup -- the UI shows text as plain text plus the entity ranges
produced here (offsets in UTF-16 code units, as TDLib gives them and as QML strings index).
"""

TEXT_MAX = 16 * 1024
PREVIEW_MAX = 200
TITLE_MAX = 256
NAME_MAX = 128
URL_MAX = 2048
ENTITIES_MAX = 512
LIST_MAX = 500

ENTITY_TYPES = {
    "textEntityTypeBold": "bold",
    "textEntityTypeItalic": "italic",
    "textEntityTypeUnderline": "underline",
    "textEntityTypeStrikethrough": "strikethrough",
    "textEntityTypeSpoiler": "spoiler",
    "textEntityTypeCode": "code",
    "textEntityTypePre": "pre",
    "textEntityTypePreCode": "preCode",
    "textEntityTypeBlockQuote": "blockQuote",
    "textEntityTypeExpandableBlockQuote": "blockQuote",
    "textEntityTypeTextUrl": "textUrl",
    "textEntityTypeUrl": "url",
    "textEntityTypeMention": "mention",
    "textEntityTypeMentionName": "mentionName",
    "textEntityTypeHashtag": "hashtag",
    "textEntityTypeCashtag": "cashtag",
    "textEntityTypeBotCommand": "botCommand",
    "textEntityTypeEmailAddress": "email",
    "textEntityTypePhoneNumber": "phone",
    "textEntityTypeCustomEmoji": "customEmoji",
}

CONTENT_KINDS = {
    "messageText": "text",
    "messagePhoto": "photo",
    "messageSticker": "sticker",
    "messageAnimation": "gif",
    "messageVoiceNote": "voice",
    "messageVideoNote": "videoNote",
    "messageVideo": "video",
    "messageDocument": "file",
    "messageAudio": "audio",
    "messageAnimatedEmoji": "emoji",
    "messageContact": "contact",
    "messageLocation": "location",
    "messageVenue": "location",
    "messagePoll": "poll",
    "messageDice": "emoji",
}

PREVIEW_LABELS = {
    "photo": "Photo", "sticker": "Sticker", "gif": "GIF", "voice": "Voice message",
    "videoNote": "Video message", "video": "Video", "file": "File", "audio": "Audio",
    "contact": "Contact", "location": "Location", "poll": "Poll", "service": "Service message",
    "unsupported": "Message",
}

WAITING_STATES = {
    "authorizationStateWaitTdlibParameters": "starting",
    "authorizationStateWaitPhoneNumber": "phone",
    "authorizationStateReady": "ready",
    "authorizationStateLoggingOut": "loggingOut",
    "authorizationStateClosing": "closing",
    "authorizationStateClosed": "closed",
}


# ---------------------------------------------------------------- reading TDLib values

def _int(value, default=0):
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    # int64 values arrive as strings in TDLib's JSON.
    if isinstance(value, str) and 0 < len(value) <= 20 and value.lstrip("-").isdigit():
        return int(value)
    return default


def _str(value, limit):
    return value[:limit] if isinstance(value, str) else ""


def _obj(value, type_name=None):
    if not isinstance(value, dict):
        return {}
    if type_name is not None and value.get("@type") != type_name:
        return {}
    return value


def _list(value, limit):
    return value[:limit] if isinstance(value, list) else []


def utf16_length(text):
    return len(text.encode("utf-16-le")) // 2


def formatted(value):
    """(text, entities) from a formattedText."""
    ft = _obj(value)
    text = _str(ft.get("text"), TEXT_MAX)
    size = utf16_length(text)
    entities = []
    for raw in _list(ft.get("entities"), ENTITIES_MAX):
        entity = _obj(raw)
        kind = _obj(entity.get("type"))
        name = ENTITY_TYPES.get(kind.get("@type"))
        offset, length = _int(entity.get("offset"), -1), _int(entity.get("length"), -1)
        if not name or offset < 0 or length <= 0 or offset + length > size:
            continue
        item = {"type": name, "offset": offset, "length": length}
        if name == "textUrl":
            item["url"] = _str(kind.get("url"), URL_MAX)
        elif name == "mentionName":
            item["userId"] = _int(kind.get("user_id"))
        elif name == "preCode":
            item["language"] = _str(kind.get("language"), 64)
        entities.append(item)
    return text, entities


def content(value):
    c = _obj(value)
    kind_name = c.get("@type") if isinstance(c.get("@type"), str) else ""
    if kind_name == "messageText":
        text, entities = formatted(c.get("text"))
        return {"kind": "text", "text": text, "entities": entities}
    kind = CONTENT_KINDS.get(kind_name)
    if kind is None:
        kind = "service" if kind_name.startswith(("messageChat", "messagePin", "messageBasicGroup",
                                                  "messageSupergroup", "messageContactRegistered")) else "unsupported"
    text, entities = formatted(c.get("caption")) if "caption" in c else ("", [])
    out = {"kind": kind, "text": text, "entities": entities}
    if kind == "sticker":
        out["emoji"] = _str(_obj(c.get("sticker")).get("emoji"), 16)
    elif kind == "file":
        out["fileName"] = _str(_obj(c.get("document")).get("file_name"), TITLE_MAX)
    elif kind == "emoji":
        out["text"] = _str(c.get("emoji"), 16)
    elif kind in ("service", "unsupported"):
        out["type"] = _str(kind_name, 64)
    return out


def preview_text(summary):
    kind, text = summary.get("kind"), summary.get("text", "")
    if kind in ("text", "emoji"):
        body = text
    elif kind == "sticker":
        body = f"{summary.get('emoji', '')} Sticker".strip()
    elif kind == "file" and summary.get("fileName") and not text:
        body = summary["fileName"]
    else:
        label = PREVIEW_LABELS.get(kind, "Message")
        body = f"{label}, {text}" if text else label
    return " ".join(body.split())[:PREVIEW_MAX]


def list_key(chat_list):
    cl = _obj(chat_list)
    t = cl.get("@type")
    if t == "chatListMain":
        return "main"
    if t == "chatListArchive":
        return "archive"
    if t == "chatListFolder":
        return f"folder:{_int(cl.get('chat_folder_id'))}"
    return None


def auth_view(state):
    s = _obj(state)
    t = s.get("@type")
    if t in WAITING_STATES:
        return {"state": WAITING_STATES[t]}
    if t == "authorizationStateWaitCode":
        info = _obj(s.get("code_info"))
        kind = _obj(info.get("type"))
        return {"state": "code", "phone": _str(info.get("phone_number"), 32),
                "via": _str(kind.get("@type"), 64).replace("authenticationCodeType", "") or "unknown",
                "length": _int(kind.get("length"))}
    if t == "authorizationStateWaitPassword":
        return {"state": "password", "hint": _str(s.get("password_hint"), 128)}
    if t == "authorizationStateWaitOtherDeviceConfirmation":
        return {"state": "qr", "link": _str(s.get("link"), URL_MAX)}
    return {"state": "unsupported", "reason": _str(t, 64)}


# ---------------------------------------------------------------- the account

class State:
    def __init__(self):
        self.chats = {}
        self.users = {}
        self.me_id = 0

    # -------------------------------------------------- names

    def user_name(self, user_id):
        user = self.users.get(user_id)
        if not user:
            return ""
        return user["name"]

    def sender(self, value):
        s = _obj(value)
        if s.get("@type") == "messageSenderUser":
            uid = _int(s.get("user_id"))
            return {"type": "user", "id": uid}, self.user_name(uid)
        if s.get("@type") == "messageSenderChat":
            cid = _int(s.get("chat_id"))
            chat = self.chats.get(cid)
            return {"type": "chat", "id": cid}, chat["title"] if chat else ""
        return {"type": "unknown", "id": 0}, ""

    # -------------------------------------------------- messages

    def message(self, value):
        m = _obj(value, "message")
        if not m:
            return None
        sender, name = self.sender(m.get("sender_id"))
        sending = _obj(m.get("sending_state")).get("@type")
        out = {
            "id": _int(m.get("id")),
            "chatId": _int(m.get("chat_id")),
            "date": _int(m.get("date")),
            "editDate": _int(m.get("edit_date")),
            "outgoing": m.get("is_outgoing") is True,
            "pinned": m.get("is_pinned") is True,
            "sender": sender,
            "senderName": name,
            "sending": {"messageSendingStatePending": "pending", "messageSendingStateFailed": "failed"}.get(sending),
            "replyTo": None,
            "content": content(m.get("content")),
        }
        reply = _obj(m.get("reply_to"), "messageReplyToMessage")
        if reply:
            out["replyTo"] = {"chatId": _int(reply.get("chat_id")), "messageId": _int(reply.get("message_id"))}
        return out

    def preview(self, value):
        message = self.message(value)
        if message is None:
            return None
        return {"id": message["id"], "date": message["date"], "outgoing": message["outgoing"],
                "senderName": message["senderName"], "text": preview_text(message["content"])}

    # -------------------------------------------------- chats

    def _chat(self, chat_id):
        return self.chats.get(chat_id)

    def _set_position(self, chat, position):
        pos = _obj(position, "chatPosition")
        key = list_key(pos.get("list"))
        if key is None:
            return
        order = _int(pos.get("order"))
        if order == 0:
            chat["positions"].pop(key, None)
        else:
            chat["positions"][key] = {"order": order, "pinned": pos.get("is_pinned") is True}

    def chat_view(self, chat_id):
        chat = self.chats.get(chat_id)
        if chat is None:
            return None
        main = chat["positions"].get("main", {})
        return {
            "id": chat["id"],
            "title": chat["title"],
            "kind": chat["kind"],
            "userId": chat["userId"],
            "unread": chat["unread"],
            "mentions": chat["mentions"],
            "muted": chat["muteFor"] > 0,
            "order": main.get("order", 0),
            "pinned": main.get("pinned", False),
            "archived": "archive" in chat["positions"],
            "lists": sorted(chat["positions"]),
            "lastReadInbox": chat["lastReadInbox"],
            "lastReadOutbox": chat["lastReadOutbox"],
            "lastMessage": chat["lastMessage"],
        }

    def chat_list(self, key="main", limit=LIST_MAX):
        rows = [(chat["positions"][key]["order"], cid) for cid, chat in self.chats.items() if key in chat["positions"]]
        rows.sort(reverse=True)
        return [self.chat_view(cid) for _, cid in rows[:limit]]

    def _new_chat(self, value):
        c = _obj(value, "chat")
        cid = _int(c.get("id"))
        if not cid:
            return None
        kind_obj = _obj(c.get("type"))
        kind = {"chatTypePrivate": "private", "chatTypeBasicGroup": "group",
                "chatTypeSecret": "secret"}.get(kind_obj.get("@type"))
        if kind_obj.get("@type") == "chatTypeSupergroup":
            kind = "channel" if kind_obj.get("is_channel") is True else "group"
        chat = {
            "id": cid,
            "title": _str(c.get("title"), TITLE_MAX),
            "kind": kind or "unknown",
            "userId": _int(kind_obj.get("user_id")),
            "unread": max(0, _int(c.get("unread_count"))),
            "mentions": max(0, _int(c.get("unread_mention_count"))),
            "muteFor": max(0, _int(_obj(c.get("notification_settings")).get("mute_for"))),
            "positions": {},
            "lastReadInbox": _int(c.get("last_read_inbox_message_id")),
            "lastReadOutbox": _int(c.get("last_read_outbox_message_id")),
            "lastMessage": None,
        }
        self.chats[cid] = chat
        for position in _list(c.get("positions"), 16):
            self._set_position(chat, position)
        chat["lastMessage"] = self.preview(c.get("last_message"))
        return cid

    # -------------------------------------------------- updates

    def apply(self, update):
        """Fold one TDLib update in; return the events the UI should hear about."""
        u = _obj(update)
        t = u.get("@type")
        handler = getattr(self, "_on_" + t, None) if isinstance(t, str) and t.startswith("update") else None
        return handler(u) if handler else []

    def _chat_event(self, cid):
        view = self.chat_view(cid)
        return [{"event": "chat", "chat": view}] if view else []

    def _on_updateNewChat(self, u):
        cid = self._new_chat(u.get("chat"))
        return self._chat_event(cid) if cid else []

    def _on_updateChatTitle(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["title"] = _str(u.get("title"), TITLE_MAX)
        return self._chat_event(chat["id"])

    def _on_updateChatLastMessage(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["lastMessage"] = self.preview(u.get("last_message"))
        for position in _list(u.get("positions"), 16):
            self._set_position(chat, position)
        return self._chat_event(chat["id"])

    def _on_updateChatPosition(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        self._set_position(chat, u.get("position"))
        return self._chat_event(chat["id"])

    def _on_updateChatReadInbox(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["unread"] = max(0, _int(u.get("unread_count")))
        chat["lastReadInbox"] = _int(u.get("last_read_inbox_message_id"))
        return self._chat_event(chat["id"])

    def _on_updateChatReadOutbox(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["lastReadOutbox"] = _int(u.get("last_read_outbox_message_id"))
        return self._chat_event(chat["id"])

    def _on_updateChatUnreadMentionCount(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["mentions"] = max(0, _int(u.get("unread_mention_count")))
        return self._chat_event(chat["id"])

    def _on_updateChatNotificationSettings(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["muteFor"] = max(0, _int(_obj(u.get("notification_settings")).get("mute_for")))
        return self._chat_event(chat["id"])

    def _on_updateUser(self, u):
        user = _obj(u.get("user"), "user")
        uid = _int(user.get("id"))
        if not uid:
            return []
        usernames = _list(_obj(user.get("usernames")).get("active_usernames"), 4)
        name = " ".join(p for p in (_str(user.get("first_name"), NAME_MAX), _str(user.get("last_name"), NAME_MAX)) if p)
        self.users[uid] = {"id": uid, "name": name or (_str(usernames[0], NAME_MAX) if usernames else "")}
        return [{"event": "user", "user": self.users[uid]}]

    def _on_updateNewMessage(self, u):
        message = self.message(u.get("message"))
        return [{"event": "message", "message": message}] if message else []

    def _on_updateMessageContent(self, u):
        return [{"event": "messageContent", "chatId": _int(u.get("chat_id")), "messageId": _int(u.get("message_id")),
                 "content": content(u.get("new_content"))}]

    def _on_updateMessageEdited(self, u):
        return [{"event": "messageEdited", "chatId": _int(u.get("chat_id")), "messageId": _int(u.get("message_id")),
                 "editDate": _int(u.get("edit_date"))}]

    def _on_updateDeleteMessages(self, u):
        if u.get("is_permanent") is not True:
            return []   # only dropped from the local cache; still exists on the server
        ids = [_int(i) for i in _list(u.get("message_ids"), 1000)]
        return [{"event": "messagesDeleted", "chatId": _int(u.get("chat_id")), "messageIds": [i for i in ids if i]}]

    def _on_updateMessageSendSucceeded(self, u):
        message = self.message(u.get("message"))
        if not message:
            return []
        return [{"event": "messageSent", "oldMessageId": _int(u.get("old_message_id")), "message": message}]

    def _on_updateMessageSendFailed(self, u):
        message = self.message(u.get("message"))
        if not message:
            return []
        error = _obj(u.get("error"))
        return [{"event": "messageFailed", "oldMessageId": _int(u.get("old_message_id")), "message": message,
                 "error": _str(error.get("message"), 200)}]
