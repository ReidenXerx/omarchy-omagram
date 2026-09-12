#!/usr/bin/python3
"""python3 tests/settings_test.py -- omagram_settings with a fake Hyprland: nothing is bound for real."""
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "bin"))
import omagram_settings as prefs  # noqa: E402
import plugin_safety as safe  # noqa: E402

LUA_STRING = r'"((?:[^"\\]|\\\d{3})*)"'


def lua_unescape(text):
    return re.sub(r"\\(\d{3})", lambda m: chr(int(m.group(1))), text)


class Result:
    def __init__(self, ok, stdout):
        self.ok = ok
        self.stdout = stdout.encode() if isinstance(stdout, str) else stdout

    def text(self):
        return self.stdout.decode()


class FakeHyprland:
    """hyprctl binds -j and hyprctl eval with hl.bind / hl.unbind, on an in-memory table."""

    def __init__(self):
        self.binds = []      # dicts as `hyprctl binds -j` gives them
        self.evals = []
        self.fail_bind = False

    def __call__(self, args):
        if list(args) == ["binds", "-j"]:
            return Result(True, json.dumps(self.binds))
        assert args[0] == "eval", args
        statement = args[1]
        self.evals.append(statement)
        m = re.fullmatch(r"hl\.bind\(%s, hl\.dsp\.exec_cmd\(%s\), \{ description = %s \}\)" % (LUA_STRING, LUA_STRING, LUA_STRING),
                         statement)
        if m:
            if self.fail_bind:
                return Result(False, "error: bad key")
            mask, key = prefs.combo_parts(lua_unescape(m.group(1)))
            self.binds.append({"modmask": mask, "key": key.upper(), "description": lua_unescape(m.group(3)),
                               "arg": lua_unescape(m.group(2))})
            return Result(True, "ok")
        m = re.fullmatch(r"hl\.unbind\(%s\)" % LUA_STRING, statement)
        if m:
            mask, key = prefs.combo_parts(lua_unescape(m.group(1)))
            self.binds = [b for b in self.binds if not (b["modmask"] == mask and b["key"].lower() == key)]
            return Result(True, "ok")
        return Result(False, "error: unexpected statement")


class Combos(unittest.TestCase):
    def test_normalized_combinations(self):
        self.assertEqual(prefs.normalize_combo("super+alt+m"), "SUPER + ALT + M")
        self.assertEqual(prefs.normalize_combo("Shift + Ctrl + ,"), "CTRL + SHIFT + COMMA")
        self.assertEqual(prefs.normalize_combo("META + enter"), "SUPER + RETURN")
        self.assertEqual(prefs.normalize_combo("SUPER + F13"), "SUPER + F13")
        for bad in ("M", "SHIFT + A", "SUPER +", "SUPER + NOPE", "SUPER + SUPER + M", 'SUPER + "', "SUPER + M + ALT",
                    "HYPER + M", "SUPER + F25", "", None, 5, "SUPER + " + "A" * 80):
            self.assertIsNone(prefs.normalize_combo(bad), bad)

    def test_lua_strings_cannot_be_broken_out_of(self):
        hostile = 'x") os.execute("rm -rf ~") --\n\\ \x00 ü'
        literal = prefs.lua_string(hostile)
        inner = literal[1:-1]
        self.assertNotIn('"', inner)
        self.assertNotIn("\n", inner)
        self.assertEqual(lua_unescape(inner).encode("latin-1"), hostile.encode("utf-8"))
        self.assertEqual(prefs.lua_string("SUPER + ALT + M"), '"SUPER + ALT + M"')


class Checking(unittest.TestCase):
    def test_strict_checks(self):
        good = {"shortcuts": {"window.voice": ["Ctrl+Alt+V", "Ctrl+Alt+V"], "list.pin": []},
                "globalShortcuts": {"global.quickReply": "super + alt + m", "global.panel": ""}}
        self.assertEqual(prefs.check(good), {"shortcuts": {"window.voice": ["Ctrl+Alt+V"], "list.pin": []},
                                             "globalShortcuts": {"global.quickReply": "SUPER + ALT + M"}, "playbackRate": 1})
        self.assertEqual([prefs.check(dict(good, playbackRate=r))["playbackRate"] for r in (1, 1.5, 2)], [1, 1.5, 2])
        for bad in ([], {"shortcuts": []}, {"playbackRate": 3}, {"playbackRate": True}, {"playbackRate": "2"},
                    {"shortcuts": {"Bad Id": ["A"]}}, {"shortcuts": {"window.voice": "A"}},
                    {"shortcuts": {"window.voice": ["has space"]}}, {"shortcuts": {"window.voice": ["A"] * 7}},
                    {"shortcuts": {"global.quickReply": ["A"]}}, {"globalShortcuts": {"global.nope": "SUPER + M"}},
                    {"globalShortcuts": {"global.quickReply": "M"}},
                    {"globalShortcuts": {"global.quickReply": "SUPER + M", "global.panel": "super+m"}},
                    {"shortcuts": {f"window.a{'x' * i}": ["A"] for i in range(201)}}):
            with self.assertRaises(ValueError, msg=repr(bad)[:80]):
                prefs.check(bad)

    def test_lenient_reading_keeps_what_is_right(self):
        mixed = {"shortcuts": {"window.voice": ["Ctrl+Alt+V"], "Bad Id": ["A"], "list.pin": "P"},
                 "globalShortcuts": {"global.quickReply": "SUPER + M", "global.panel": "nonsense"}, "playbackRate": 7}
        self.assertEqual(prefs.check(mixed, strict=False),
                         {"shortcuts": {"window.voice": ["Ctrl+Alt+V"]}, "globalShortcuts": {"global.quickReply": "SUPER + M"},
                          "playbackRate": 1})
        self.assertEqual(prefs.check("junk", strict=False), prefs.empty())


class Storing(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="omagram-settings-", dir=safe.runtime_dir()))
        self.addCleanup(shutil.rmtree, self.root, True)
        for name, value in (("CONFIG", self.root / "omagram"), ("SETTINGS", self.root / "omagram" / "settings.json")):
            patch = mock.patch.object(prefs, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def test_round_trip_private_files(self):
        self.assertEqual(prefs.load(), prefs.empty())
        settings = prefs.check({"shortcuts": {"window.voice": ["Ctrl+Alt+V"]}})
        prefs.save(settings)
        self.assertEqual(os.stat(prefs.SETTINGS).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(prefs.CONFIG).st_mode & 0o777, 0o700)
        self.assertEqual(prefs.load(), settings)

    def test_broken_or_foreign_files_are_ignored(self):
        prefs.CONFIG.mkdir(mode=0o700)
        prefs.SETTINGS.write_text("{ not json")
        self.assertEqual(prefs.load(), prefs.empty())
        prefs.SETTINGS.unlink()
        target = self.root / "elsewhere.json"
        target.write_text(json.dumps({"shortcuts": {"window.voice": ["Ctrl+Alt+V"]}}))
        prefs.SETTINGS.symlink_to(target)
        self.assertEqual(prefs.load(), prefs.empty())
        with self.assertRaises((safe.UnsafeError, OSError)):
            prefs.save(prefs.empty())


class Registering(unittest.TestCase):
    def setUp(self):
        self.hypr = FakeHyprland()
        patch = mock.patch.object(prefs, "hyprctl", self.hypr)
        patch.start()
        self.addCleanup(patch.stop)

    def ours(self):
        return sorted((b["modmask"], b["key"], b["description"]) for b in self.hypr.binds
                      if b["description"].startswith(prefs.DESCRIPTION_PREFIX))

    def test_bind_change_and_clear(self):
        status = prefs.apply({"global.quickReply": "SUPER + ALT + M"})
        self.assertEqual(status, {"global.quickReply": "active", "global.panel": "off", "global.openWindow": "off"})
        self.assertEqual(self.ours(), [(72, "M", "Omagram: Quick reply")])
        bound = next(b for b in self.hypr.binds if b["description"] == "Omagram: Quick reply")
        self.assertEqual(bound["arg"], "/usr/bin/omarchy-shell shell toggle reidenxerx.omagram '{}'")
        evals = len(self.hypr.evals)
        prefs.apply({"global.quickReply": "SUPER + ALT + M"})
        self.assertEqual(len(self.hypr.evals), evals, "already bound: nothing to do")
        prefs.apply({"global.quickReply": "SUPER + CTRL + M"})
        self.assertEqual(self.ours(), [(68, "M", "Omagram: Quick reply")])
        prefs.apply({})
        self.assertEqual(self.ours(), [])

    def test_keys_you_bound_yourself_are_never_touched(self):
        mine = {"modmask": 72, "key": "M", "description": "My music player", "arg": "player"}
        self.hypr.binds.append(dict(mine))
        status = prefs.apply({"global.quickReply": "SUPER + ALT + M", "global.panel": "SUPER + ALT + P"})
        self.assertEqual((status["global.quickReply"], status["global.panel"]), ("taken", "active"))
        self.assertIn(mine, self.hypr.binds)
        prefs.apply({})
        self.assertIn(mine, self.hypr.binds)
        self.assertEqual(self.ours(), [])

    def test_swapping_two_shortcuts_rebinds_both(self):
        prefs.apply({"global.quickReply": "SUPER + ALT + M", "global.panel": "SUPER + ALT + P"})
        status = prefs.apply({"global.quickReply": "SUPER + ALT + P", "global.panel": "SUPER + ALT + M"})
        self.assertEqual((status["global.quickReply"], status["global.panel"]), ("active", "active"))
        self.assertEqual(self.ours(), [(72, "M", "Omagram: Bar panel"), (72, "P", "Omagram: Quick reply")])

    def test_after_a_config_reload_they_come_back_and_failures_are_reported(self):
        prefs.apply({"global.openWindow": "SUPER + SHIFT + T"})
        self.hypr.binds = []   # what a Hyprland config reload does to runtime bindings
        self.assertEqual(prefs.apply({"global.openWindow": "SUPER + SHIFT + T"})["global.openWindow"], "active")
        self.assertEqual(len(self.ours()), 1)
        self.hypr.binds = []
        self.hypr.fail_bind = True
        self.assertEqual(prefs.apply({"global.openWindow": "SUPER + SHIFT + T"})["global.openWindow"], "failed")


if __name__ == "__main__":
    unittest.main(verbosity=1)
