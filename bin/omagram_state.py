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
FOLDERS_MAX = 64
REACTIONS_MAX = 20
MARKUP_ROWS_MAX = 12
MARKUP_COLUMNS_MAX = 8
BUTTON_TEXT_MAX = 64
CALLBACK_DATA_MAX = 128       # base64 of Telegram's 64-byte callback data
COPY_TEXT_MAX = 4096
POLL_OPTIONS_MAX = 12
POLL_TEXT_MAX = 300
DESCRIPTION_MAX = 600
GROUPS_MAX = 20000
MEMBER_STATUSES = {"chatMemberStatusCreator": "owner", "chatMemberStatusAdministrator": "admin",
                   "chatMemberStatusMember": "member", "chatMemberStatusRestricted": "restricted",
                   "chatMemberStatusLeft": "left", "chatMemberStatusBanned": "banned"}
SECRET_STATES = {"secretChatStatePending": "pending", "secretChatStateReady": "ready", "secretChatStateClosed": "closed"}
CALL_STATES = {"callStatePending": "pending", "callStateExchangingKeys": "connecting", "callStateReady": "ready",
               "callStateHangingUp": "ending", "callStateDiscarded": "ended", "callStateError": "failed"}
CALLS_MAX = 16
STORY_CHATS_MAX = 500
STORIES_PER_CHAT_MAX = 100
STORY_ID_MAX = 2 ** 31 - 1
STORY_LISTS = {"storyListMain": "main", "storyListArchive": "archive"}

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


def _float(value, low, high):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if low <= number <= high else None   # NaN fails both comparisons


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
        elif name == "customEmoji":
            item["customEmojiId"] = str(_int(kind.get("custom_emoji_id")))
        entities.append(item)
    return text, entities


SERVICE_PREFIXES = ("messageChat", "messagePin", "messageBasicGroup", "messageSupergroup", "messageContactRegistered",
                    "messageCall", "messageVideoChat", "messageScreenshotTaken", "messageForumTopic",
                    "messageCustomServiceAction")


def content(value, files_root=""):
    c = _obj(value)
    kind_name = c.get("@type") if isinstance(c.get("@type"), str) else ""
    if kind_name == "messageText":
        text, entities = formatted(c.get("text"))
        out = {"kind": "text", "text": text, "entities": entities}
        preview = link_preview(c.get("link_preview"), files_root)
        if preview is not None:
            out["linkPreview"] = preview
        return out
    kind = CONTENT_KINDS.get(kind_name)
    if kind is None:
        kind = "service" if kind_name.startswith(SERVICE_PREFIXES) else "unsupported"
    text, entities = formatted(c.get("caption")) if "caption" in c else ("", [])
    out = {"kind": kind, "text": text, "entities": entities}
    if kind == "sticker":
        out["emoji"] = _str(_obj(c.get("sticker")).get("emoji"), 16)
    elif kind == "file":
        out["fileName"] = _str(_obj(c.get("document")).get("file_name"), TITLE_MAX)
    elif kind == "emoji":
        out["text"] = _str(c.get("emoji"), 16)
        if kind_name == "messageDice" and _int(c.get("value")) > 0:   # what it came up with, once the server says
            out["text"] += f" {_int(c.get('value'))}"
    elif kind in ("service", "unsupported"):
        out["type"] = _str(kind_name, 64)
    elif kind == "poll":
        poll = poll_view(c.get("poll"))
        if poll is not None:
            out["poll"] = poll
            out["text"] = poll["question"]
    elif kind == "location":
        place = location_view(c)
        if place is not None:
            out["location"] = place
            out["text"] = place["title"]
    elif kind == "contact":
        person = contact_view(c.get("contact"))
        if person is not None:
            out["contact"] = person
            out["text"] = person["name"]
    if c.get("has_spoiler") is True:
        out["spoiler"] = True   # the media stays covered until you choose to see it
    media = media_for(kind, c, files_root)
    if media is not None:
        out["media"] = media
    return out


def link_preview(value, files_root):
    p = _obj(value, "linkPreview")
    url = _str(p.get("url"), URL_MAX) if p else ""
    if not url:
        return None
    description, _ = formatted(p.get("description"))
    out = {"url": url, "displayUrl": _str(p.get("display_url"), URL_MAX), "siteName": _str(p.get("site_name"), TITLE_MAX),
           "title": _str(p.get("title"), TITLE_MAX), "description": description[:DESCRIPTION_MAX], "photo": None}
    kind = _obj(p.get("type"))
    photo = _obj(kind.get("photo"), "photo") if kind.get("@type") in ("linkPreviewTypeArticle", "linkPreviewTypePhoto") else {}
    best = best_photo_size(photo.get("sizes")) if photo else None
    if best is not None:
        w, h, size = best
        out["photo"] = {"file": file_view(size.get("photo"), files_root), "width": w, "height": h,
                        "mini": minithumbnail(photo.get("minithumbnail"))}
    return out


def poll_view(value):
    p = _obj(value, "poll")
    if not p:
        return None
    question, _ = formatted(p.get("question"))
    options = []
    for index, raw in enumerate(_list(p.get("options"), POLL_OPTIONS_MAX)):
        o = _obj(raw, "pollOption")
        text, _ = formatted(o.get("text"))
        options.append({"index": index, "text": text[:POLL_TEXT_MAX], "voters": max(0, _int(o.get("voter_count"))),
                        "percent": max(0, min(100, _int(o.get("vote_percentage")))), "chosen": o.get("is_chosen") is True})
    kind = _obj(p.get("type"))
    quiz = kind.get("@type") == "pollTypeQuiz"
    correct = [_int(i) for i in _list(kind.get("correct_option_ids"), POLL_OPTIONS_MAX)] if quiz else []
    return {"id": str(_int(p.get("id"))), "question": question[:POLL_TEXT_MAX], "options": options,
            "total": max(0, _int(p.get("total_voter_count"))), "closed": p.get("is_closed") is True,
            "anonymous": p.get("is_anonymous") is True, "multiple": p.get("allows_multiple_answers") is True,
            "canRevote": p.get("allows_revoting") is True, "quiz": quiz, "correct": correct,
            "voted": any(o["chosen"] for o in options)}


def location_view(c):
    venue = _obj(c.get("venue"), "venue")
    loc = _obj(venue.get("location") if venue else c.get("location"), "location")
    lat, lon = _float(loc.get("latitude"), -90, 90), _float(loc.get("longitude"), -180, 180)
    if lat is None or lon is None:
        return None
    return {"lat": lat, "lon": lon, "title": _str(venue.get("title"), TITLE_MAX) if venue else "",
            "address": _str(venue.get("address"), TITLE_MAX) if venue else ""}


def contact_view(value):
    person = _obj(value, "contact")
    if not person:
        return None
    name = " ".join(p for p in (_str(person.get("first_name"), NAME_MAX), _str(person.get("last_name"), NAME_MAX)) if p)
    return {"name": name, "phone": _str(person.get("phone_number"), 32), "userId": _int(person.get("user_id"))}


INLINE_BUTTONS = {
    "inlineKeyboardButtonTypeCallback": "callback", "inlineKeyboardButtonTypeUrl": "url",
    "inlineKeyboardButtonTypeLoginUrl": "url", "inlineKeyboardButtonTypeWebApp": "webApp",
    "inlineKeyboardButtonTypeSwitchInline": "switchInline", "inlineKeyboardButtonTypeUser": "user",
    "inlineKeyboardButtonTypeCopyText": "copy", "inlineKeyboardButtonTypeCallbackGame": "game",
    "inlineKeyboardButtonTypeBuy": "buy", "inlineKeyboardButtonTypeCallbackWithPassword": "password",
    "inlineKeyboardButtonTypeDisabled": "disabled",
}
KEYBOARD_BUTTONS = {"keyboardButtonTypeText": "text", "keyboardButtonTypeRequestPhoneNumber": "requestPhone",
                    "keyboardButtonTypeRequestLocation": "requestLocation"}


def _button_rows(value, button_type, convert):
    rows = []
    for raw_row in _list(value, MARKUP_ROWS_MAX):
        row = [b for b in (convert(_obj(raw, button_type)) for raw in _list(raw_row, MARKUP_COLUMNS_MAX)) if b]
        if row:
            rows.append(row)
    return rows


def _inline_button(b):
    if not b:
        return None
    kind_obj = _obj(b.get("type"))
    button = {"text": _str(b.get("text"), BUTTON_TEXT_MAX), "kind": INLINE_BUTTONS.get(kind_obj.get("@type"), "unsupported")}
    if button["kind"] == "callback":
        data = kind_obj.get("data")
        if isinstance(data, str) and 0 < len(data) <= CALLBACK_DATA_MAX:
            button["data"] = data
        else:
            button["kind"] = "unsupported"
    elif button["kind"] in ("url", "webApp"):
        button["url"] = _str(kind_obj.get("url"), URL_MAX)
    elif button["kind"] == "user":
        button["userId"] = _int(kind_obj.get("user_id"))
    elif button["kind"] == "copy":
        button["copyText"] = _str(kind_obj.get("text"), COPY_TEXT_MAX)
    elif button["kind"] == "switchInline":
        button["query"] = _str(kind_obj.get("query"), 256)
    return button


def _keyboard_button(b):
    if not b:
        return None
    return {"text": _str(b.get("text"), BUTTON_TEXT_MAX),
            "kind": KEYBOARD_BUTTONS.get(_obj(b.get("type")).get("@type"), "unsupported")}


def reply_markup(value):
    """A bot's buttons under a message, or its keyboard for the message box."""
    m = _obj(value)
    t = m.get("@type")
    if t == "replyMarkupInlineKeyboard":
        rows = _button_rows(m.get("rows"), "inlineKeyboardButton", _inline_button)
        return {"type": "inline", "rows": rows} if rows else None
    if t == "replyMarkupShowKeyboard":
        rows = _button_rows(m.get("rows"), "keyboardButton", _keyboard_button)
        return {"type": "keyboard", "rows": rows, "oneTime": m.get("one_time") is True,
                "resize": m.get("resize_keyboard") is True, "persistent": m.get("is_persistent") is True,
                "placeholder": _str(m.get("input_field_placeholder"), BUTTON_TEXT_MAX)} if rows else None
    if t == "replyMarkupRemoveKeyboard":
        return {"type": "remove"}
    if t == "replyMarkupForceReply":
        return {"type": "forceReply", "placeholder": _str(m.get("input_field_placeholder"), BUTTON_TEXT_MAX)}
    return None


def reactions_view(value):
    """(reactions, view count) from a message's interaction info."""
    info = _obj(value, "messageInteractionInfo")
    out = []
    for raw in _list(_obj(info.get("reactions")).get("reactions"), REACTIONS_MAX):
        r = _obj(raw, "messageReaction")
        kind = _obj(r.get("type"))
        count = max(0, _int(r.get("total_count")))
        if not count:
            continue
        chosen = r.get("is_chosen") is True
        if kind.get("@type") == "reactionTypeEmoji" and _str(kind.get("emoji"), 16):
            out.append({"emoji": _str(kind.get("emoji"), 16), "count": count, "chosen": chosen})
        elif kind.get("@type") == "reactionTypeCustomEmoji":
            out.append({"emoji": "", "customEmojiId": str(_int(kind.get("custom_emoji_id"))), "count": count, "chosen": chosen})
        elif kind.get("@type") == "reactionTypePaid":
            out.append({"emoji": "⭐", "paid": True, "count": count, "chosen": chosen})
    return out, max(0, _int(info.get("view_count")))


def replies_view(value):
    """The comments under a channel post, or the replies to a message in a discussion group: how many,
    and whether any came after the last one you read. None for a message with no thread."""
    r = _obj(value, "messageReplyInfo")
    if not r:
        return None
    last = _int(r.get("last_message_id"))
    return {"count": max(0, _int(r.get("reply_count"))), "unread": last > max(0, _int(r.get("last_read_inbox_message_id")))}


USER_STATUSES = {"userStatusRecently": "recently", "userStatusLastWeek": "lastWeek", "userStatusLastMonth": "lastMonth"}


def status_view(value):
    s = _obj(value)
    t = s.get("@type")
    if t == "userStatusOnline":
        return {"state": "online", "expires": _int(s.get("expires"))}
    if t == "userStatusOffline":
        return {"state": "offline", "wasOnline": _int(s.get("was_online"))}
    return {"state": USER_STATUSES.get(t, "")}


def draft_text(value):
    d = _obj(value, "draftMessage")
    c = _obj(d.get("content"), "draftMessageContentText") if d else {}
    return formatted(c.get("text"))[0] if c else ""


def formatted_view(value):
    text, entities = formatted(value)
    return {"text": text, "entities": entities}


def topic_id(value):
    """The forum topic a message is in, or 0 when it is not in one."""
    return max(0, _int(_obj(value, "messageTopicForum").get("forum_topic_id")))


def thread_id(value):
    """The thread a message is in (comments under a post, replies to a message), or 0."""
    return max(0, _int(_obj(value, "messageTopicThread").get("message_thread_id")))


def scheduled_at(value):
    """When a scheduled message goes out: its date, -1 once the other person is online, 0 when it
    is not scheduled."""
    s = _obj(value)
    t = s.get("@type")
    if t in ("messageSchedulingStateSendAtDate", "messageSchedulingStateSendWhenVideoProcessed"):
        return max(1, _int(s.get("send_date")))
    return -1 if t == "messageSchedulingStateSendWhenOnline" else 0


def key_hash_view(value):
    """A secret chat's key fingerprint as groups of hex, to compare with the other device."""
    import base64
    import binascii
    if not isinstance(value, str) or not 0 < len(value) <= 256:
        return ""
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        return ""
    hexed = raw[:32].hex()
    return " ".join(hexed[i:i + 8] for i in range(0, len(hexed), 8))


SESSION_DEVICES = ("android", "apple", "brave", "chrome", "edge", "firefox", "ipad", "iphone", "linux", "mac", "opera",
                   "safari", "ubuntu", "vivaldi", "windows", "xbox")


def session_view(value):
    """A device signed in to the account, as Settings lists it."""
    s = _obj(value, "session")
    if not s:
        return None
    sid = _int(s.get("id"))   # the device you are using has id 0
    device = _str(_obj(s.get("device_type")).get("@type"), 64).replace("sessionDeviceType", "").lower()
    return {"id": str(sid), "current": s.get("is_current") is True, "passwordPending": s.get("is_password_pending") is True,
            "unconfirmed": s.get("is_unconfirmed") is True, "official": s.get("is_official_application") is True,
            "app": _str(s.get("application_name"), NAME_MAX), "appVersion": _str(s.get("application_version"), 64),
            "device": _str(s.get("device_model"), NAME_MAX), "platform": _str(s.get("platform"), 64),
            "system": _str(s.get("system_version"), 64), "loginDate": max(0, _int(s.get("log_in_date"))),
            "lastActive": max(0, _int(s.get("last_active_date"))), "ip": _str(s.get("ip_address"), 64),
            "location": _str(s.get("location"), NAME_MAX), "type": device if device in SESSION_DEVICES else "unknown"}


PRIVACY_SETTINGS = {   # the privacy settings Settings shows, by the ids the window uses
    "status": "userPrivacySettingShowStatus",
    "photo": "userPrivacySettingShowProfilePhoto",
    "phone": "userPrivacySettingShowPhoneNumber",
    "findByPhone": "userPrivacySettingAllowFindingByPhoneNumber",
    "bio": "userPrivacySettingShowBio",
    "birthdate": "userPrivacySettingShowBirthdate",
    "forwards": "userPrivacySettingShowLinkInForwardedMessages",
    "calls": "userPrivacySettingAllowCalls",
    "invites": "userPrivacySettingAllowChatInvites",
}
PRIVACY_BASES = {"userPrivacySettingRuleAllowAll": "everybody", "userPrivacySettingRuleAllowContacts": "contacts",
                 "userPrivacySettingRuleRestrictAll": "nobody"}
PRIVACY_RULES_MAX = 64
PRIVACY_IDS_MAX = 10000


def privacy_rule_list(value):
    rules = (_obj(raw) for raw in _list(_obj(value, "userPrivacySettingRules").get("rules"), PRIVACY_RULES_MAX))
    return [r for r in rules if isinstance(r.get("@type"), str) and r["@type"].startswith("userPrivacySettingRule")]


def privacy_view(value):
    """A privacy setting as Settings shows it: who in general -- everybody, your contacts or nobody (what no
    rule allows is not allowed) -- and how many people and chats are exceptions either way."""
    base, allowed, restricted = "", 0, 0
    for rule in privacy_rule_list(value):
        kind = rule["@type"]
        if kind in PRIVACY_BASES:
            base = base or PRIVACY_BASES[kind]
            continue
        count = len(_list(rule.get("user_ids"), PRIVACY_IDS_MAX)) + len(_list(rule.get("chat_ids"), PRIVACY_IDS_MAX))
        if kind.startswith("userPrivacySettingRuleAllow"):
            allowed += count
        else:
            restricted += count
    return {"base": base or "nobody", "allowed": allowed, "restricted": restricted}


def privacy_rules(value, base):
    """The rules again with `base` as the general rule, after the exceptions that still mean something:
    people allowed when not everybody is, people kept out when not nobody is."""
    general = {"everybody": "userPrivacySettingRuleAllowAll", "contacts": "userPrivacySettingRuleAllowContacts",
               "nobody": "userPrivacySettingRuleRestrictAll"}[base]
    kept = []
    for rule in privacy_rule_list(value):
        kind = rule["@type"]
        if kind in PRIVACY_BASES:
            continue
        allows = kind.startswith("userPrivacySettingRuleAllow")
        if (allows and base == "everybody") or (not allows and base == "nobody"):
            continue
        kept.append(rule)
    return {"@type": "userPrivacySettingRules", "rules": kept + [{"@type": general}]}


def password_view(value):
    """Two-step verification: whether a password is set, its hint, the recovery email, and a code
    Telegram emailed that still waits to be typed."""
    p = _obj(value, "passwordState")
    code = _obj(p.get("recovery_email_address_code_info"), "emailAddressAuthenticationCodeInfo")
    return {"hasPassword": p.get("has_password") is True, "hint": _str(p.get("password_hint"), NAME_MAX),
            "hasRecoveryEmail": p.get("has_recovery_email_address") is True,
            "emailCodePattern": _str(code.get("email_address_pattern"), NAME_MAX) if code else "",
            "emailCodeLength": max(0, _int(code.get("length"))) if code else 0,
            "resetDate": max(0, _int(p.get("pending_reset_date")))}


FOLDER_FLAGS = {"includeContacts": "include_contacts", "includeNonContacts": "include_non_contacts",
                "includeGroups": "include_groups", "includeChannels": "include_channels", "includeBots": "include_bots",
                "excludeMuted": "exclude_muted", "excludeRead": "exclude_read", "excludeArchived": "exclude_archived"}
FOLDER_IDS_MAX = 1000


def folder_ids(value):
    return [i for i in (_int(x) for x in _list(value, FOLDER_IDS_MAX)) if i]


def folder_view(value, fid):
    """A chat folder as Settings edits it: its name, the kinds of chats it takes, what it leaves out, and the
    chats pinned in it, always in it and never in it."""
    f = _obj(value, "chatFolder")
    if not f or fid <= 0:
        return None
    name, _ = formatted(_obj(f.get("name")).get("text"))
    view = {"id": fid, "name": _str(name, NAME_MAX), "icon": _str(_obj(f.get("icon")).get("name"), 32),
            "colorId": _int(f.get("color_id"), -1), "shareable": f.get("is_shareable") is True,
            "pinned": folder_ids(f.get("pinned_chat_ids")), "included": folder_ids(f.get("included_chat_ids")),
            "excluded": folder_ids(f.get("excluded_chat_ids"))}
    for key, field in FOLDER_FLAGS.items():
        view[key] = f.get(field) is True
    return view


NOTIFICATION_SCOPES = {"private": "notificationSettingsScopePrivateChats", "groups": "notificationSettingsScopeGroupChats",
                       "channels": "notificationSettingsScopeChannelChats"}
SCOPE_FIELDS = ("mute_for", "sound_id", "show_preview", "use_default_mute_stories", "mute_stories", "story_sound_id",
                "show_story_poster", "disable_pinned_message_notifications", "disable_mention_notifications")
SCOPE_MUTED = 2 ** 31 - 1


def scope_view(value):
    """Notifications for a type of chat, as Settings shows them: muted or not, message text shown or not."""
    s = _obj(value, "scopeNotificationSettings")
    return {"muted": _int(s.get("mute_for")) > 0, "preview": s.get("show_preview") is True}


def scope_settings(value, muted=None, preview=None):
    """A type of chat's notification settings as TDLib wants them back, only the mute or the preview changed."""
    s = _obj(value, "scopeNotificationSettings")
    out = {"@type": "scopeNotificationSettings"}
    for field in SCOPE_FIELDS:
        if field in ("sound_id", "story_sound_id"):
            out[field] = _int(s.get(field))
        elif field == "mute_for":
            out[field] = max(0, _int(s.get(field)))
        else:
            out[field] = s.get(field) is True
    if muted is not None:
        out["mute_for"] = SCOPE_MUTED if muted else 0
    if preview is not None:
        out["show_preview"] = preview
    return out


NOTIFICATION_FLAGS = ("use_default_mute_for", "use_default_sound", "use_default_show_preview", "show_preview",
                      "use_default_mute_stories", "mute_stories", "use_default_story_sound",
                      "use_default_show_story_poster", "show_story_poster",
                      "use_default_disable_pinned_message_notifications", "disable_pinned_message_notifications",
                      "use_default_disable_mention_notifications", "disable_mention_notifications")


def notification_settings(value):
    """A chat's notification settings as TDLib wants them back, so muting changes only the mute."""
    s = _obj(value)
    out = {"@type": "chatNotificationSettings", "mute_for": max(0, _int(s.get("mute_for")))}
    for flag in NOTIFICATION_FLAGS:
        out[flag] = s.get(flag) is True
    for field in ("sound_id", "story_sound_id"):
        out[field] = str(_int(s.get(field)))
    return out


CHAT_ACTIONS = {
    "chatActionTyping": "typing", "chatActionRecordingVideo": "recordingVideo", "chatActionUploadingVideo": "uploadingVideo",
    "chatActionRecordingVoiceNote": "recordingVoice", "chatActionUploadingVoiceNote": "uploadingVoice",
    "chatActionUploadingPhoto": "uploadingPhoto", "chatActionUploadingDocument": "uploadingFile",
    "chatActionChoosingSticker": "choosingSticker", "chatActionChoosingLocation": "choosingLocation",
    "chatActionChoosingContact": "choosingContact", "chatActionStartPlayingGame": "playingGame",
    "chatActionRecordingVideoNote": "recordingVideoNote", "chatActionUploadingVideoNote": "uploadingVideoNote",
    "chatActionWatchingAnimations": "watchingAnimations", "chatActionCancel": "cancel",
}


def clock_duration(seconds):
    hours, rest = divmod(max(0, int(seconds)), 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def human_period(seconds):
    for unit, size in (("day", 86400), ("hour", 3600), ("minute", 60)):
        if seconds >= size and seconds % size == 0:
            count = seconds // size
            return f"{count} {unit}{'' if count == 1 else 's'}"
    return f"{seconds} seconds"


# ---------------------------------------------------------------- media

MINI_MAX = 16 * 1024          # base64 length of a minithumbnail (a tiny JPEG)
WAVEFORM_MAX = 256            # base64 length of a voice waveform
WAVEFORM_BARS = 48
PHOTO_SIDE_MAX = 1280
DURATION_MAX = 7 * 24 * 3600
STICKER_FORMATS = {"stickerFormatWebp": "webp", "stickerFormatTgs": "tgs", "stickerFormatWebm": "webm"}
THUMBNAIL_FORMATS = {"thumbnailFormatJpeg": "jpeg", "thumbnailFormatGif": "gif", "thumbnailFormatMpeg4": "mp4",
                     "thumbnailFormatPng": "png", "thumbnailFormatTgs": "tgs", "thumbnailFormatWebm": "webm",
                     "thumbnailFormatWebp": "webp"}


def local_path(value, files_root):
    """A downloaded file's path, only if it is an absolute path inside one of the media
    directories TDLib downloads into: the UI loads it as a file:// URL and must never be
    pointed anywhere else. `files_root` is one directory or a tuple of them (TDLib keeps
    stickers and thumbnails beside its database, everything else in its files directory)."""
    roots = (files_root,) if isinstance(files_root, str) else tuple(files_root or ())
    roots = tuple(r.rstrip("/") + "/" for r in roots if isinstance(r, str) and r.startswith("/"))
    if not roots or not isinstance(value, str) or not value.startswith("/") or len(value) > 4096:
        return ""
    if any(ord(ch) < 32 or ch == "\x7f" for ch in value):
        return ""
    parts = value.split("/")
    if ".." in parts or "." in parts or "" in parts[1:]:
        return ""
    return value if value.startswith(roots) else ""


def file_view(value, files_root):
    f = _obj(value, "file")
    fid = _int(f.get("id"))
    if fid <= 0:
        return None
    local = _obj(f.get("local"))
    completed = local.get("is_downloading_completed") is True
    return {
        "id": fid,
        "size": max(0, _int(f.get("size")), _int(f.get("expected_size"))),
        "downloaded": max(0, _int(local.get("downloaded_size"))),
        "active": local.get("is_downloading_active") is True,
        "path": local_path(local.get("path"), files_root) if completed else "",
    }


def minithumbnail(value):
    m = _obj(value, "minithumbnail")
    data = m.get("data")
    if not isinstance(data, str) or not 0 < len(data) <= MINI_MAX:
        return None
    return {"width": max(0, _int(m.get("width"))), "height": max(0, _int(m.get("height"))), "data": data}


def thumbnail(value, files_root):
    t = _obj(value, "thumbnail")
    view = file_view(t.get("file"), files_root) if t else None
    if view is None:
        return None
    return {"format": THUMBNAIL_FORMATS.get(_obj(t.get("format")).get("@type"), "unknown"),
            "width": max(0, _int(t.get("width"))), "height": max(0, _int(t.get("height"))), "file": view}


def waveform(value, bars=WAVEFORM_BARS):
    """A voice waveform as up to `bars` values 0-31. Telegram packs 5 bits per sample,
    least significant first; buckets keep their loudest sample."""
    import base64
    import binascii
    if not isinstance(value, str) or not 0 < len(value) <= WAVEFORM_MAX:
        return []
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        return []
    count = len(raw) * 8 // 5
    packed = int.from_bytes(raw, "little")
    samples = [(packed >> (i * 5)) & 31 for i in range(count)]
    if len(samples) <= bars:
        return samples
    step = len(samples) / bars
    return [max(samples[int(i * step):max(int(i * step) + 1, int((i + 1) * step))]) for i in range(bars)]


def _dims(obj):
    return max(0, min(_int(obj.get("width")), 100000)), max(0, min(_int(obj.get("height")), 100000))


def _duration(obj):
    return max(0, min(_int(obj.get("duration")), DURATION_MAX))


def best_photo_size(sizes):
    usable = []
    for raw in _list(sizes, 16):
        size = _obj(raw, "photoSize")
        w, h = _dims(size)
        if size and w and h and _obj(size.get("photo"), "file"):
            usable.append((w, h, size))
    if not usable:
        return None
    fitting = [u for u in usable if max(u[0], u[1]) <= PHOTO_SIDE_MAX]
    return max(fitting or usable, key=lambda u: u[0] * u[1] if fitting else -(u[0] * u[1]))


def media_for(kind, c, files_root):
    if kind == "photo":
        photo = _obj(c.get("photo"))
        best = best_photo_size(photo.get("sizes"))
        if best is None:
            return None
        w, h, size = best
        return {"file": file_view(size.get("photo"), files_root), "width": w, "height": h,
                "mini": minithumbnail(photo.get("minithumbnail"))}
    if kind == "sticker":
        s = _obj(c.get("sticker"), "sticker")
        view = file_view(s.get("sticker"), files_root)
        if view is None:
            return None
        w, h = _dims(s)
        return {"file": view, "format": STICKER_FORMATS.get(_obj(s.get("format")).get("@type"), "unknown"),
                "width": w, "height": h, "emoji": _str(s.get("emoji"), 16),
                "thumb": thumbnail(s.get("thumbnail"), files_root),
                # The set it belongs to, as text (int64): a sticker in a chat leads to its set.
                "setId": str(_int(s.get("set_id"))) if _int(s.get("set_id")) else ""}
    if kind == "gif":
        a = _obj(c.get("animation"), "animation")
        view = file_view(a.get("animation"), files_root)
        if view is None:
            return None
        w, h = _dims(a)
        return {"file": view, "width": w, "height": h, "duration": _duration(a), "mime": _str(a.get("mime_type"), 128),
                "thumb": thumbnail(a.get("thumbnail"), files_root), "mini": minithumbnail(a.get("minithumbnail"))}
    if kind == "voice":
        v = _obj(c.get("voice_note"), "voiceNote")
        view = file_view(v.get("voice"), files_root)
        if view is None:
            return None
        return {"file": view, "duration": _duration(v), "waveform": waveform(v.get("waveform")),
                "mime": _str(v.get("mime_type"), 128), "listened": c.get("is_listened") is True}
    if kind == "videoNote":
        v = _obj(c.get("video_note"), "videoNote")
        view = file_view(v.get("video"), files_root)
        if view is None:
            return None
        return {"file": view, "duration": _duration(v), "length": max(0, min(_int(v.get("length")), 4096)),
                "thumb": thumbnail(v.get("thumbnail"), files_root), "mini": minithumbnail(v.get("minithumbnail")),
                "viewed": c.get("is_viewed") is True}
    if kind == "video":
        v = _obj(c.get("video"), "video")
        view = file_view(v.get("video"), files_root)
        if view is None:
            return None
        w, h = _dims(v)
        return {"file": view, "width": w, "height": h, "duration": _duration(v), "fileName": _str(v.get("file_name"), TITLE_MAX),
                "thumb": thumbnail(v.get("thumbnail"), files_root), "mini": minithumbnail(v.get("minithumbnail"))}
    if kind == "file":
        d = _obj(c.get("document"), "document")
        view = file_view(d.get("document"), files_root)
        if view is None:
            return None
        return {"file": view, "fileName": _str(d.get("file_name"), TITLE_MAX), "mime": _str(d.get("mime_type"), 128),
                "thumb": thumbnail(d.get("thumbnail"), files_root)}
    if kind == "audio":
        a = _obj(c.get("audio"), "audio")
        view = file_view(a.get("audio"), files_root)
        if view is None:
            return None
        return {"file": view, "duration": _duration(a), "title": _str(a.get("title"), TITLE_MAX),
                "performer": _str(a.get("performer"), TITLE_MAX), "fileName": _str(a.get("file_name"), TITLE_MAX),
                "mime": _str(a.get("mime_type"), 128)}
    return None


def preview_text(summary):
    kind, text = summary.get("kind"), summary.get("text", "")
    if kind in ("text", "emoji") or (kind == "service" and text):
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

FILE_MARKS_MAX = 4096
USERS_MAX = 50000


class State:
    def __init__(self, files_root=""):
        self.chats = {}
        self.users = {}
        self.basic_groups = {}     # basic group id -> {"memberCount", "status"}
        self.supergroups = {}      # supergroup id -> {"memberCount", "status", "username", "forum"}
        self.secret_chats = {}     # secret chat id -> {"state", "outbound", "userId", "keyHash"}
        self.calls = {}            # call id -> the call as the "call" event shows it, while it lasts
        self.active_stories = {}   # chat id -> its active stories, as the "stories" event shows them
        self.me_id = 0
        self.folders = []          # [{"id", "name", "icon"}] in Telegram's order
        self.main_position = 0     # where "All chats" sits among the folders
        # TDLib's files directory: only paths inside it are ever handed to the UI.
        self.files_root = files_root
        self.file_marks = {}

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
        body = content(m.get("content"), self.files_root)
        if body["kind"] == "service":
            body["text"] = self.service_text(_obj(m.get("content")), sender, name, _int(m.get("chat_id")))
        reactions, views = reactions_view(m.get("interaction_info"))
        album = _int(m.get("media_album_id"))
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
            "content": body,
            "forward": self.forward_view(m.get("forward_info")),
            "albumId": str(album) if album else "",
            "reactions": reactions,
            "canSeeReactions": _obj(_obj(m.get("interaction_info")).get("reactions")).get("can_get_added_reactions") is True,
            "views": views,
            "markup": reply_markup(m.get("reply_markup")),
            "topicId": topic_id(m.get("topic_id")),
            "threadId": thread_id(m.get("topic_id")),
            "replies": replies_view(_obj(m.get("interaction_info")).get("reply_info")),
            "sendAt": scheduled_at(m.get("scheduling_state")),
        }
        reply = _obj(m.get("reply_to"), "messageReplyToMessage")
        if reply:
            out["replyTo"] = {"chatId": _int(reply.get("chat_id")), "messageId": _int(reply.get("message_id"))}
        return out

    def forward_view(self, value):
        """Who a forwarded message came from, as a name to show."""
        f = _obj(value, "messageForwardInfo")
        if not f:
            return None
        origin = _obj(f.get("origin"))
        t = origin.get("@type")
        name = ""
        if t == "messageOriginUser":
            name = self.user_name(_int(origin.get("sender_user_id")))
        elif t == "messageOriginHiddenUser":
            name = _str(origin.get("sender_name"), NAME_MAX)
        elif t in ("messageOriginChat", "messageOriginChannel"):
            chat = self.chats.get(_int(origin.get("sender_chat_id" if t == "messageOriginChat" else "chat_id")))
            name = chat["title"] if chat else ""
            signature = _str(origin.get("author_signature"), NAME_MAX)
            if signature:
                name = f"{name} ({signature})" if name else signature
        return {"name": name or "Unknown", "date": _int(f.get("date"))}

    def service_text(self, c, sender, actor, chat_id):
        """What happened, in a sentence: "Ann added Bob", "Missed call". "" when not understood."""
        t = c.get("@type")
        who = actor or "Someone"
        actor_id = sender["id"] if sender.get("type") == "user" else 0
        chat = self.chats.get(chat_id)
        place = "channel" if chat and chat["kind"] == "channel" else "group"

        def user(uid):
            return self.user_name(uid) or "someone"

        if t == "messageChatAddMembers":
            ids = [_int(i) for i in _list(c.get("member_user_ids"), 20)]
            if ids == [actor_id]:
                return f"{who} joined the {place}"
            return f"{who} added {', '.join(user(i) for i in ids)}" if ids else f"{who} added members"
        if t == "messageChatJoinByLink":
            return f"{who} joined the {place} with an invite link"
        if t == "messageChatJoinByRequest":
            return f"{who} joined the {place}"
        if t == "messageChatDeleteMember":
            uid = _int(c.get("user_id"))
            return f"{who} left the {place}" if uid == actor_id else f"{who} removed {user(uid)}"
        if t == "messageChatChangeTitle":
            return f"{who} renamed the {place} to “{_str(c.get('title'), TITLE_MAX)}”"
        if t == "messageChatChangePhoto":
            return f"{who} changed the {place} photo"
        if t == "messageChatDeletePhoto":
            return f"{who} removed the {place} photo"
        if t == "messagePinMessage":
            return f"{who} pinned a message"
        if t in ("messageBasicGroupChatCreate", "messageSupergroupChatCreate"):
            return f"{who} created the {place} “{_str(c.get('title'), TITLE_MAX)}”"
        if t in ("messageChatUpgradeTo", "messageChatUpgradeFrom"):
            return "The group was upgraded to a supergroup"
        if t == "messageScreenshotTaken":
            return f"{who} took a screenshot"
        if t == "messageContactRegistered":
            return f"{who} joined Telegram"
        if t == "messageCall":
            seconds = max(0, _int(c.get("duration")))
            kind = "Video call" if c.get("is_video") is True else "Call"
            return f"{kind}, {clock_duration(seconds)}" if seconds else f"Missed {kind.lower()}"
        if t == "messageVideoChatStarted":
            return f"{who} started a video chat"
        if t == "messageVideoChatEnded":
            return f"Video chat ended, {clock_duration(max(0, _int(c.get('duration'))))}"
        if t == "messageChatSetMessageAutoDeleteTime":
            seconds = max(0, _int(c.get("message_auto_delete_time")))
            return (f"{who} set messages to disappear after {human_period(seconds)}" if seconds
                    else f"{who} turned off disappearing messages")
        if t == "messageForumTopicCreated":
            return f"Topic “{_str(c.get('name'), TITLE_MAX)}” was created"
        if t == "messageForumTopicEdited":
            name = _str(c.get("name"), TITLE_MAX)
            return f"{who} renamed the topic to “{name}”" if name else f"{who} edited the topic"
        if t == "messageCustomServiceAction":
            return _str(c.get("text"), PREVIEW_MAX)
        if t == "messageChatSetTheme":
            return f"{who} changed the chat theme"
        if t == "messageChatSetBackground":
            return f"{who} changed the chat background"
        if t == "messageChatBoost":
            return f"{who} boosted the {place}"
        return ""

    def preview(self, value):
        message = self.message(value)
        if message is None:
            return None
        return {"id": message["id"], "date": message["date"], "outgoing": message["outgoing"],
                "senderName": message["senderName"], "text": preview_text(message["content"])}

    def member_view(self, value):
        """One member of a group: who, and whether they own it, run it or just belong."""
        m = _obj(value, "chatMember")
        sender, name = self.sender(m.get("member_id"))
        if not sender["id"]:
            return None
        user = self.users.get(sender["id"], {}) if sender["type"] == "user" else {}
        return {"type": sender["type"], "id": sender["id"], "name": name,
                "status": MEMBER_STATUSES.get(_obj(m.get("status")).get("@type"), "member"),
                "tag": _str(m.get("tag"), 64), "bot": user.get("bot", False), "userStatus": user.get("status")}

    def topic_view(self, value):
        """A topic of a forum group, as its list shows it."""
        t = _obj(value, "forumTopic")
        info = _obj(t.get("info"), "forumTopicInfo")
        tid = _int(info.get("forum_topic_id"))
        if tid <= 0:
            return None
        icon = _obj(info.get("icon"), "forumTopicIcon")
        return {"id": tid, "chatId": _int(info.get("chat_id")), "name": _str(info.get("name"), TITLE_MAX),
                "color": _int(icon.get("color")) & 0xFFFFFF, "general": info.get("is_general") is True,
                "closed": info.get("is_closed") is True, "hidden": info.get("is_hidden") is True,
                "pinned": t.get("is_pinned") is True, "unread": max(0, _int(t.get("unread_count"))),
                "mentions": max(0, _int(t.get("unread_mention_count"))), "order": str(max(0, _int(t.get("order")))),
                "lastMessage": self.preview(t.get("last_message")), "draft": draft_text(t.get("draft_message"))}

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

    def group_of(self, chat):
        if chat["supergroupId"]:
            return self.supergroups.get(chat["supergroupId"], {})
        if chat["basicGroupId"]:
            return self.basic_groups.get(chat["basicGroupId"], {})
        return {}

    def chat_view(self, chat_id):
        chat = self.chats.get(chat_id)
        if chat is None:
            return None
        main = chat["positions"].get("main", {})
        group = self.group_of(chat)
        secret = self.secret_chats.get(chat["secretChatId"]) if chat["secretChatId"] else None
        return {
            "id": chat["id"],
            "title": chat["title"],
            "photo": chat["photo"],
            "kind": chat["kind"],
            "userId": chat["userId"],
            "unread": chat["unread"],
            "mentions": chat["mentions"],
            "unreadReactions": chat.get("reactions", 0),   # messages of yours with reactions you have not seen
            "muted": chat["muteFor"] > 0,
            # int64 order, as text: a JavaScript number would round it and shuffle the list.
            "order": str(main.get("order", 0)),
            "pinned": main.get("pinned", False),
            "archived": "archive" in chat["positions"],
            "lists": sorted(chat["positions"]),
            # Every list the chat is in, with its order there (as text) and whether it is pinned there.
            "positions": {key: {"order": str(pos["order"]), "pinned": pos["pinned"]}
                          for key, pos in chat["positions"].items()},
            "lastReadInbox": chat["lastReadInbox"],
            "lastReadOutbox": chat["lastReadOutbox"],
            "lastMessage": chat["lastMessage"],
            "draft": chat["draft"],
            "markedUnread": chat["markedUnread"],
            # The other person's status and whether they are a bot, for a private chat.
            "status": self.users.get(chat["userId"], {}).get("status") if chat["userId"] else None,
            "bot": self.users.get(chat["userId"], {}).get("bot", False) if chat["userId"] else False,
            # A group's size and your place in it, a public username, and whether it is a forum of topics.
            "memberCount": group.get("memberCount", 0),
            "myStatus": group.get("status", ""),
            "username": group.get("username", "") if chat["supergroupId"] else self.users.get(chat["userId"], {}).get("username", ""),
            "forum": group.get("forum", False),
            # A supergroup or channel can be joined, a basic group you left cannot; a channel's
            # discussion group may take messages from people who have not joined it.
            "supergroup": chat["supergroupId"] != 0,
            "joinToWrite": chat["kind"] != "group" or group.get("joinToSend", True),
            "hasScheduled": chat["hasScheduled"],
            # A secret chat: pending until the other side accepts, then ready, or closed. Its key
            # fingerprint is for the info page only.
            "secret": {"state": secret["state"], "outbound": secret["outbound"]} if secret else None,
        }

    def chat_list(self, key="main", limit=LIST_MAX):
        rows = [(chat["positions"][key]["order"], cid) for cid, chat in self.chats.items() if key in chat["positions"]]
        rows.sort(reverse=True)
        return [self.chat_view(cid) for _, cid in rows[:limit]]

    def all_chats(self, limit=LIST_MAX):
        """Every known chat that is in some list: the main list in order, then the rest."""
        rows = sorted((cid for cid, c in self.chats.items() if c["positions"]),
                      key=lambda cid: (-self.chats[cid]["positions"].get("main", {}).get("order", 0), cid))
        return [self.chat_view(cid) for cid in rows[:limit]]

    def folders_event(self):
        return {"event": "folders", "folders": self.folders, "mainPosition": self.main_position}

    def _photo(self, value):
        """A chat's small photo (a user's, for a private chat) and its inline thumbnail."""
        p = _obj(value, "chatPhotoInfo")
        small = file_view(p.get("small"), self.files_root) if p else None
        return {"file": small, "mini": minithumbnail(p.get("minithumbnail"))} if small else None

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
            "basicGroupId": _int(kind_obj.get("basic_group_id")),
            "supergroupId": _int(kind_obj.get("supergroup_id")),
            "secretChatId": _int(kind_obj.get("secret_chat_id")),
            "hasScheduled": c.get("has_scheduled_messages") is True,
            "markedUnread": c.get("is_marked_as_unread") is True,
            "unread": max(0, _int(c.get("unread_count"))),
            "mentions": max(0, _int(c.get("unread_mention_count"))),
            "reactions": max(0, _int(c.get("unread_reaction_count"))),
            "muteFor": max(0, _int(_obj(c.get("notification_settings")).get("mute_for"))),
            "positions": {},
            "lastReadInbox": _int(c.get("last_read_inbox_message_id")),
            "lastReadOutbox": _int(c.get("last_read_outbox_message_id")),
            "lastMessage": None,
            "photo": self._photo(c.get("photo")),
            "draft": draft_text(c.get("draft_message")),
            "notification": notification_settings(c.get("notification_settings")),
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

    def _on_updateChatPhoto(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["photo"] = self._photo(u.get("photo"))
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

    def _on_updateChatUnreadReactionCount(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["reactions"] = max(0, _int(u.get("unread_reaction_count")))
        return self._chat_event(chat["id"])

    def _on_updateMessageUnreadReactions(self, u):
        return self._on_updateChatUnreadReactionCount(u)

    def _on_updateChatNotificationSettings(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["muteFor"] = max(0, _int(_obj(u.get("notification_settings")).get("mute_for")))
        chat["notification"] = notification_settings(u.get("notification_settings"))
        return self._chat_event(chat["id"])

    def _on_updateChatIsMarkedAsUnread(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["markedUnread"] = u.get("is_marked_as_unread") is True
        return self._chat_event(chat["id"])

    @staticmethod
    def _keep_group(groups, gid, view):
        groups.pop(gid, None)
        groups[gid] = view
        while len(groups) > GROUPS_MAX:
            del groups[next(iter(groups))]

    def _group_chat_events(self, key, gid):
        return [event for cid, chat in self.chats.items() if chat[key] == gid for event in self._chat_event(cid)]

    def _on_updateBasicGroup(self, u):
        g = _obj(u.get("basic_group"), "basicGroup")
        gid = _int(g.get("id"))
        if gid <= 0:
            return []
        self._keep_group(self.basic_groups, gid, {"memberCount": max(0, _int(g.get("member_count"))),
                                                  "status": MEMBER_STATUSES.get(_obj(g.get("status")).get("@type"), "")})
        return self._group_chat_events("basicGroupId", gid)

    def _on_updateSupergroup(self, u):
        g = _obj(u.get("supergroup"), "supergroup")
        gid = _int(g.get("id"))
        if gid <= 0:
            return []
        usernames = _list(_obj(g.get("usernames")).get("active_usernames"), 4)
        self._keep_group(self.supergroups, gid, {"memberCount": max(0, _int(g.get("member_count"))),
                                                 "status": MEMBER_STATUSES.get(_obj(g.get("status")).get("@type"), ""),
                                                 "username": _str(usernames[0], NAME_MAX) if usernames else "",
                                                 "forum": g.get("is_forum") is True,
                                                 # TDLib's own answer to "must you join before writing": false
                                                 # only where people who have not joined may write, as in a
                                                 # channel's discussion group that takes comments from anyone.
                                                 "joinToSend": g.get("join_to_send_messages") is not False})
        return self._group_chat_events("supergroupId", gid)

    def _on_updateChatHasScheduledMessages(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["hasScheduled"] = u.get("has_scheduled_messages") is True
        return self._chat_event(chat["id"])

    def _on_updateSecretChat(self, u):
        s = _obj(u.get("secret_chat"), "secretChat")
        sid = _int(s.get("id"))
        if sid <= 0:
            return []
        self._keep_group(self.secret_chats, sid, {"state": SECRET_STATES.get(_obj(s.get("state")).get("@type"), "pending"),
                                                  "outbound": s.get("is_outbound") is True, "userId": _int(s.get("user_id")),
                                                  "keyHash": key_hash_view(s.get("key_hash"))})
        return self._group_chat_events("secretChatId", sid)

    def _on_updateCall(self, u):
        c = _obj(u.get("call"), "call")
        cid = _int(c.get("id"))
        if cid <= 0:
            return []
        uid = _int(c.get("user_id"))
        view = {"id": cid, "userId": uid, "name": self.user_name(uid), "outgoing": c.get("is_outgoing") is True,
                "video": c.get("is_video") is True, "state": CALL_STATES.get(_obj(c.get("state")).get("@type"), "pending")}
        if view["state"] in ("ended", "failed"):
            self.calls.pop(cid, None)
        else:
            self.calls[cid] = view
            while len(self.calls) > CALLS_MAX:
                del self.calls[next(iter(self.calls))]
        return [{"event": "call", "call": view}]

    # -------------------------------------------------- stories

    def _on_updateChatActiveStories(self, u):
        a = _obj(u.get("active_stories"), "chatActiveStories")
        chat_id = _int(a.get("chat_id"))
        if not chat_id:
            return []
        stories = []
        for raw in _list(a.get("stories"), STORIES_PER_CHAT_MAX):
            info = _obj(raw, "storyInfo")
            sid = _int(info.get("story_id"))
            if 0 < sid <= STORY_ID_MAX:
                stories.append({"id": sid, "date": _int(info.get("date")), "closeFriends": info.get("is_for_close_friends") is True,
                                "live": info.get("is_live") is True})
        chat = self.chats.get(chat_id)
        view = {"chatId": chat_id, "list": STORY_LISTS.get(_obj(a.get("list")).get("@type"), ""),
                "order": str(max(0, _int(a.get("order")))), "maxReadId": max(0, _int(a.get("max_read_story_id"))),
                "title": chat["title"] if chat else "", "stories": stories}
        self.active_stories.pop(chat_id, None)
        if stories:
            self.active_stories[chat_id] = view
            while len(self.active_stories) > STORY_CHATS_MAX:
                del self.active_stories[next(iter(self.active_stories))]
        return [{"event": "stories", "stories": view}]

    def story_list(self):
        return list(self.active_stories.values())

    def story_view(self, value):
        """A story to show: its photo or video as the window's media views describe them, and its
        caption. Live and other stories are named by kind only."""
        s = _obj(value, "story")
        sid, chat_id = _int(s.get("id")), _int(s.get("poster_chat_id"))
        if not 0 < sid <= STORY_ID_MAX or not chat_id:
            return None
        content = _obj(s.get("content"))
        t = content.get("@type")
        kind, media = "unsupported", None
        if t == "storyContentPhoto":
            media = media_for("photo", {"photo": content.get("photo")}, self.files_root)
            kind = "photo" if media else "unsupported"
        elif t == "storyContentVideo":
            v = _obj(content.get("video"), "storyVideo")
            view = file_view(v.get("video"), self.files_root)
            if view is not None:
                d = v.get("duration")
                duration = int(d) if isinstance(d, (int, float)) and not isinstance(d, bool) and 0 <= d <= 86400 else 0
                media = {"file": view, "width": max(0, _int(v.get("width"))), "height": max(0, _int(v.get("height"))),
                         "duration": duration, "thumb": thumbnail(v.get("thumbnail"), self.files_root),
                         "mini": minithumbnail(v.get("minithumbnail"))}
                kind = "video"
        elif t == "storyContentLive":
            kind = "live"
        text, entities = formatted(s.get("caption"))
        chat = self.chats.get(chat_id)
        return {"id": sid, "chatId": chat_id, "date": _int(s.get("date")), "kind": kind, "media": media,
                "caption": {"text": text, "entities": entities}, "title": chat["title"] if chat else "",
                "protected": s.get("can_be_forwarded") is not True,
                "views": max(0, _int(_obj(s.get("interaction_info")).get("view_count")))}

    def _on_updateChatFolders(self, u):
        folders = []
        for info in _list(u.get("chat_folders"), FOLDERS_MAX):
            f = _obj(info, "chatFolderInfo")
            fid = _int(f.get("id"))
            if fid <= 0:
                continue
            name, _ = formatted(_obj(f.get("name")).get("text"))
            folders.append({"id": fid, "name": " ".join(_str(name, NAME_MAX).split()) or "Folder",
                            "icon": _str(_obj(f.get("icon")).get("name"), 32)})
        self.folders = folders
        self.main_position = max(0, _int(u.get("main_chat_list_position")))
        return [self.folders_event()]

    def _on_updateUser(self, u):
        user = _obj(u.get("user"), "user")
        uid = _int(user.get("id"))
        if not uid:
            return []
        usernames = _list(_obj(user.get("usernames")).get("active_usernames"), 4)
        name = " ".join(p for p in (_str(user.get("first_name"), NAME_MAX), _str(user.get("last_name"), NAME_MAX)) if p)
        self.users.pop(uid, None)   # inserted again: the users heard of most recently come last
        self.users[uid] = {"id": uid, "name": name or (_str(usernames[0], NAME_MAX) if usernames else ""),
                           "username": _str(usernames[0], NAME_MAX) if usernames else "",
                           "bot": _obj(user.get("type")).get("@type") == "userTypeBot",
                           "status": status_view(user.get("status")),
                           "phone": _str(user.get("phone_number"), 32)}
        self._trim_users()
        # A phone number is for a chat's info page only, not for every client's stream of events.
        return [{"event": "user", "user": {k: v for k, v in self.users[uid].items() if k != "phone"}}]

    def _trim_users(self):
        """Past the ceiling the users heard of longest ago go first -- never someone a chat is with."""
        if len(self.users) <= USERS_MAX:
            return
        keep = {chat["userId"] for chat in self.chats.values() if chat["userId"]}
        keep.add(self.me_id)
        for uid in list(self.users):
            if len(self.users) <= USERS_MAX * 9 // 10:
                break
            if uid not in keep:
                del self.users[uid]

    def _on_updateUserStatus(self, u):
        uid = _int(u.get("user_id"))
        if not uid:
            return []
        status = status_view(u.get("status"))
        if uid in self.users:
            self.users[uid]["status"] = status
        return [{"event": "userStatus", "userId": uid, "status": status}]

    def _on_updateChatDraftMessage(self, u):
        chat = self._chat(_int(u.get("chat_id")))
        if not chat:
            return []
        chat["draft"] = draft_text(u.get("draft_message"))
        for position in _list(u.get("positions"), 16):
            self._set_position(chat, position)
        return self._chat_event(chat["id"])

    def _on_updateChatAction(self, u):
        cid = _int(u.get("chat_id"))
        action = CHAT_ACTIONS.get(_obj(u.get("action")).get("@type"))
        if not cid or action is None:
            return []
        sender, name = self.sender(u.get("sender_id"))
        return [{"event": "chatAction", "chatId": cid, "senderId": sender["id"], "senderName": name, "action": action}]

    def _on_updateMessageInteractionInfo(self, u):
        cid, mid = _int(u.get("chat_id")), _int(u.get("message_id"))
        if not cid or not mid:
            return []
        reactions, views = reactions_view(u.get("interaction_info"))
        return [{"event": "messageInteraction", "chatId": cid, "messageId": mid, "reactions": reactions, "views": views,
                 "replies": replies_view(_obj(u.get("interaction_info")).get("reply_info"))}]

    def _on_updateMessageIsPinned(self, u):
        cid, mid = _int(u.get("chat_id")), _int(u.get("message_id"))
        if not cid or not mid:
            return []
        return [{"event": "messagePinned", "chatId": cid, "messageId": mid, "pinned": u.get("is_pinned") is True}]

    def _on_updatePoll(self, u):
        poll = poll_view(u.get("poll"))
        return [{"event": "poll", "poll": poll}] if poll else []

    def _on_updateForumTopicInfo(self, u):
        info = _obj(u.get("info"), "forumTopicInfo")
        cid, tid = _int(info.get("chat_id")), _int(info.get("forum_topic_id"))
        if not cid or tid <= 0:
            return []
        return [{"event": "topicInfo", "chatId": cid, "topicId": tid, "name": _str(info.get("name"), TITLE_MAX),
                 "closed": info.get("is_closed") is True, "hidden": info.get("is_hidden") is True}]

    def _on_updateForumTopic(self, u):
        cid, tid = _int(u.get("chat_id")), _int(u.get("forum_topic_id"))
        if not cid or tid <= 0:
            return []
        return [{"event": "topicUpdate", "chatId": cid, "topicId": tid, "pinned": u.get("is_pinned") is True,
                 "mentions": max(0, _int(u.get("unread_mention_count"))),
                 "lastReadInbox": _int(u.get("last_read_inbox_message_id"))}]

    def _on_updateNewMessage(self, u):
        message = self.message(u.get("message"))
        return [{"event": "message", "message": message}] if message else []

    def _on_updateMessageContent(self, u):
        return [{"event": "messageContent", "chatId": _int(u.get("chat_id")), "messageId": _int(u.get("message_id")),
                 "content": content(u.get("new_content"), self.files_root)}]

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

    def _on_updateFile(self, u):
        view = file_view(u.get("file"), self.files_root)
        if view is None:
            return []
        # Download progress arrives many times a second. A file is announced when it starts
        # or stops, when it completes, and when it has moved on by a twentieth of its size.
        last = self.file_marks.get(view["id"])
        step = max(64 * 1024, view["size"] // 20)
        if (last is not None and not view["path"] and view["active"] == last["active"]
                and view["downloaded"] - last["downloaded"] < step):
            return []
        if len(self.file_marks) >= FILE_MARKS_MAX:
            self.file_marks.clear()
        self.file_marks[view["id"]] = view
        return [{"event": "file", "file": view}]

    def _on_updateMessageSendFailed(self, u):
        message = self.message(u.get("message"))
        if not message:
            return []
        error = _obj(u.get("error"))
        return [{"event": "messageFailed", "oldMessageId": _int(u.get("old_message_id")), "message": message,
                 "error": _str(error.get("message"), 200)}]
