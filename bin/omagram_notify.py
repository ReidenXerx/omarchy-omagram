"""omagram_notify -- desktop notifications for Omagram's service, over the session bus.

Notifications go to org.freedesktop.Notifications through GLib's Gio bindings, never through
a command line, so message previews never appear in any process's arguments. On Omarchy the
shell's own notification service receives them (and applies Do Not Disturb). That server
renders body markup and hyperlinks, so everything taken from Telegram is escaped before it is
sent: a message cannot add a link or an image to its own notification.

The picture beside the text is one Omagram chooses and hands over as a file: the chat's photo, or a
thumbnail of the photo, sticker or video just sent; without one, Omagram's mark. The buttons open the chat, reply to it, mark it
read, mute it for an hour, or react to the message with a thumbs up.

One notification per chat: it is replaced as messages arrive and closed when TDLib reports the
messages read (on any device). Nothing is shown for the chat you are looking at in Omagram.
Without PyGObject the notifier is simply unavailable and the service runs without it.
"""
import html
import pathlib
import re

BUS = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"
CALL_TIMEOUT_MS = 2000
TITLE_MAX = 120
BODY_MAX = 300
CHATS_MAX = 512
QUICK_REACTION = "👍"
ACTIONS = ["default", "Open", "reply", "Reply", "read", "Mark as read", "mute", "Mute for an hour", "react", QUICK_REACTION]
ACTION_IDS = tuple(ACTIONS[0::2])
HINTS = {"category": "im.received", "desktop-entry": "omagram"}
APP_ICON = pathlib.Path(__file__).resolve().parent.parent / "assets" / "omagram.svg"   # Omagram's mark, when there is no picture

_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f  ]")


def clean(text, limit):
    text = _CONTROL.sub(" ", text if isinstance(text, str) else "")
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def body_markup(text, limit=BODY_MAX):
    return html.escape(clean(text, limit), quote=False)


class GioTransport:
    """The session bus, through Gio. Signal handlers run when pump() iterates GLib's
    default main context from the service's own loop."""

    def __init__(self, on_action, on_closed):
        import gi
        gi.require_version("Gio", "2.0")
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.bus.signal_subscribe(BUS, BUS, "ActionInvoked", PATH, None, Gio.DBusSignalFlags.NONE,
                                  lambda _c, _s, _p, _i, _n, params: on_action(*params.unpack()))
        self.bus.signal_subscribe(BUS, BUS, "NotificationClosed", PATH, None, Gio.DBusSignalFlags.NONE,
                                  lambda _c, _s, _p, _i, _n, params: on_closed(params.unpack()[0]))

    def notify(self, replaces, title, body, actions, hints):
        GLib = self.GLib
        icon = APP_ICON.as_uri() if APP_ICON.is_file() else ""
        args = GLib.Variant("(susssasa{sv}i)", ("Omagram", replaces, icon, title, body, actions,
                                                {k: GLib.Variant("s", v) for k, v in hints.items()}, -1))
        reply = self.bus.call_sync(BUS, PATH, BUS, "Notify", args, GLib.VariantType("(u)"),
                                   self.Gio.DBusCallFlags.NONE, CALL_TIMEOUT_MS, None)
        return reply.unpack()[0]

    def close(self, notification_id):
        self.bus.call_sync(BUS, PATH, BUS, "CloseNotification", self.GLib.Variant("(u)", (notification_id,)),
                           None, self.Gio.DBusCallFlags.NONE, CALL_TIMEOUT_MS, None)

    def pump(self):
        context = self.GLib.MainContext.default()
        while context.pending():
            context.iteration(False)


class Notifier:
    def __init__(self, transport_factory, on_action):
        self.on_action = on_action
        self.by_chat = {}
        self.by_id = {}
        self.focused_chat = 0
        self.transport = None
        if transport_factory is not None:
            try:
                self.transport = transport_factory(self._action, self._closed)
            except Exception:   # no PyGObject, no session bus: run without notifications
                self.transport = None

    @property
    def available(self):
        return self.transport is not None

    def show(self, chat_id, title, body, image=""):
        """`image`: the path of a picture for beside the text, or "" for none."""
        if self.transport is None or not chat_id or chat_id == self.focused_chat:
            return False
        replaces = self.by_chat.get(chat_id, 0)
        hints = dict(HINTS)
        if image:
            hints["image-path"] = pathlib.Path(image).as_uri()
        try:
            nid = self.transport.notify(replaces, clean(title, TITLE_MAX) or "Omagram", body_markup(body),
                                        ACTIONS, hints)
        except Exception:
            return False
        if not isinstance(nid, int) or nid <= 0:
            return False
        if replaces and replaces != nid:
            self.by_id.pop(replaces, None)
        if len(self.by_id) >= CHATS_MAX and nid not in self.by_id:
            self.by_chat.clear()
            self.by_id.clear()
        self.by_chat[chat_id] = nid
        self.by_id[nid] = chat_id
        return True

    def withdraw(self, chat_id):
        nid = self.by_chat.pop(chat_id, None)
        if nid is None:
            return
        self.by_id.pop(nid, None)
        try:
            self.transport.close(nid)
        except Exception:
            pass

    def focus(self, chat_id):
        self.focused_chat = chat_id
        if chat_id:
            self.withdraw(chat_id)

    def pump(self):
        if self.transport is None:
            return
        try:
            self.transport.pump()
        except Exception:
            pass

    def _action(self, nid, action):
        chat_id = self.by_id.get(nid)
        if chat_id and action in ACTION_IDS:
            self.on_action(chat_id, action)

    def _closed(self, nid, *_reason):
        chat_id = self.by_id.pop(nid, None)
        if chat_id is not None and self.by_chat.get(chat_id) == nid:
            del self.by_chat[chat_id]
