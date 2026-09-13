#!/usr/bin/python3
"""python3 tests/notify_test.py -- omagram_notify with a fake bus: nothing is shown on screen."""
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "bin"))
import omagram_notify as notify  # noqa: E402


class FakeTransport:
    def __init__(self, on_action, on_closed):
        self.on_action, self.on_closed = on_action, on_closed
        self.shown, self.closed, self.next_id, self.pumps = [], [], 100, 0
        self.fail = False

    def notify(self, replaces, title, body, actions, hints):
        if self.fail:
            raise RuntimeError("bus went away")
        self.shown.append((replaces, title, body, list(actions), dict(hints)))
        if replaces:
            return replaces
        self.next_id += 1
        return self.next_id

    def close(self, nid):
        self.closed.append(nid)

    def pump(self):
        self.pumps += 1


class Notifications(unittest.TestCase):
    def setUp(self):
        self.actions = []
        self.n = notify.Notifier(FakeTransport, lambda chat, action: self.actions.append((chat, action)))
        self.bus = self.n.transport

    def test_one_notification_per_chat_is_replaced(self):
        self.assertTrue(self.n.show(42, "Friends", "Ann: hi"))
        self.assertTrue(self.n.show(42, "Friends (2)", "Ann: again"))
        self.assertTrue(self.n.show(7, "Mom", "call me"))
        self.assertEqual([s[0] for s in self.bus.shown], [0, 101, 0])
        self.assertEqual(self.n.by_chat, {42: 101, 7: 102})
        self.assertEqual(self.bus.shown[0][3][0::2], ["default", "reply", "read", "mute", "react"])
        self.assertEqual(self.bus.shown[0][3][1::2], ["Open", "Reply", "Mark as read", "Mute for an hour", "👍"])
        self.assertEqual(self.bus.shown[0][4]["desktop-entry"], "omagram")

    def test_telegram_text_cannot_add_markup_links_or_images(self):
        self.n.show(1, "Eve", '<a href="https://evil.example">click</a> <img src="x"> & more')
        body = self.bus.shown[0][2]
        self.assertNotIn("<", body)
        self.assertIn("&lt;a href=\"https://evil.example\"&gt;click&lt;/a&gt;", body)
        self.assertIn("&amp; more", body)

    def test_control_characters_and_length_are_bounded(self):
        self.n.show(1, "Title\x1b]0;x\x07\nsecond line", "line one\n\n\tline two " + "z" * 1000)
        _, title, body, _, _ = self.bus.shown[0]
        self.assertEqual(title, "Title ]0;x second line")
        self.assertTrue(body.startswith("line one line two "))
        self.assertLessEqual(len(body), notify.BODY_MAX)
        self.assertTrue(body.endswith("…"))
        self.n.show(2, "", "x")
        self.assertEqual(self.bus.shown[1][1], "Omagram")

    def test_the_chat_you_are_reading_stays_quiet_and_is_cleared(self):
        self.n.show(42, "Friends", "hi")
        self.n.focus(42)
        self.assertEqual(self.bus.closed, [101])
        self.assertFalse(self.n.show(42, "Friends", "again"))
        self.n.focus(0)
        self.assertTrue(self.n.show(42, "Friends", "again"))

    def test_withdraw_actions_and_closed_signals(self):
        self.n.show(42, "Friends", "hi")
        self.bus.on_action(101, "reply")
        self.bus.on_action(101, "something-else")
        self.bus.on_action(999, "default")
        self.assertEqual(self.actions, [(42, "reply")])
        self.bus.on_closed(101, 2)
        self.assertEqual(self.n.by_chat, {})
        self.n.withdraw(42)
        self.assertEqual(self.bus.closed, [])
        self.n.show(5, "A", "b")
        self.n.withdraw(5)
        self.assertEqual(self.bus.closed, [102])

    def test_a_picture_goes_as_a_file_uri_and_every_button_reaches_the_service(self):
        self.n.show(42, "Friends", "hi", "/home/me/.cache/omagram/notify/a b.jpg")
        self.assertEqual(self.bus.shown[0][4]["image-path"], "file:///home/me/.cache/omagram/notify/a%20b.jpg")
        self.n.show(7, "Mom", "call me")
        self.assertNotIn("image-path", self.bus.shown[1][4])
        for action in ("read", "mute", "react", "default", "reply"):
            self.bus.on_action(101, action)
        self.assertEqual(self.actions, [(42, "read"), (42, "mute"), (42, "react"), (42, "default"), (42, "reply")])

    def test_a_failing_bus_or_no_bus_never_breaks_the_service(self):
        self.bus.fail = True
        self.assertFalse(self.n.show(1, "A", "b"))
        self.n.pump()

        def no_bus(on_action, on_closed):
            raise ImportError("No module named gi")
        off = notify.Notifier(no_bus, lambda *a: None)
        self.assertFalse(off.available)
        self.assertFalse(off.show(1, "A", "b"))
        off.withdraw(1)
        off.focus(1)
        off.pump()
        self.assertFalse(notify.Notifier(None, None).available)


if __name__ == "__main__":
    unittest.main(verbosity=1)
