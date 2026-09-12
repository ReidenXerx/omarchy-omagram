"""omagram_settings -- your shortcuts: stored, checked, and the global ones given to Hyprland.

Settings live in ~/.config/omagram/settings.json, a 0600 file in a 0700 directory, and hold only
what you changed. Shortcuts inside Omagram are key sequences the window understands (its
Keymap.js knows every action and its default keys), so here they are only checked for shape.

Shortcuts that work anywhere -- quick reply, the bar panel, opening Omagram -- are registered with
Hyprland at runtime with `hl.bind`, never written into your Hyprland config, and only when you pick
keys for them. A combination Hyprland already uses for something else is left alone and reported
as taken, and Omagram only ever removes bindings it made itself (they carry its description).
"""
import json
import pathlib
import re
import shlex
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import plugin_safety as safe  # noqa: E402

CONFIG = pathlib.Path(safe.home_dir()) / ".config" / "omagram"
SETTINGS = CONFIG / "settings.json"
SETTINGS_MAX = 64 * 1024
JSON_LIMITS = {"max_depth": 6, "max_items": 5000, "max_string": 256}
ACTIONS_MAX = 200
KEYS_MAX = 6
PLAYBACK_RATES = (1, 1.5, 2)   # how fast voice and video messages play
ACTION_ID = re.compile(r"[a-z][A-Za-z]{0,20}\.[a-z][A-Za-z]{0,40}")
SEQUENCE = re.compile(r"[\x21-\x7e]{1,40}")

BIN = pathlib.Path(__file__).resolve().parent
PLUGIN_ID = "reidenxerx.omagram"
DESCRIPTION_PREFIX = "Omagram: "
GLOBALS = {
    "global.quickReply": ("Quick reply", ["/usr/bin/omarchy-shell", "shell", "toggle", PLUGIN_ID, "{}"]),
    "global.panel": ("Bar panel", ["/usr/bin/omarchy-shell", PLUGIN_ID + ".panel", "toggle"]),
    "global.openWindow": ("Open Omagram", ["/usr/bin/python3", str(BIN / "omagram")]),
}

MODIFIER_ALIASES = {"SUPER": "SUPER", "META": "SUPER", "WIN": "SUPER", "CTRL": "CTRL", "CONTROL": "CTRL",
                    "ALT": "ALT", "SHIFT": "SHIFT"}
MODIFIER_BITS = {"SUPER": 64, "CTRL": 4, "ALT": 8, "SHIFT": 1}
MODIFIER_ORDER = ("SUPER", "CTRL", "ALT", "SHIFT")
KEY_NAMES = {"SPACE", "RETURN", "TAB", "ESCAPE", "BACKSPACE", "DELETE", "HOME", "END", "UP", "DOWN", "LEFT",
             "RIGHT", "PAGE_UP", "PAGE_DOWN", "COMMA", "PERIOD", "SLASH", "SEMICOLON", "APOSTROPHE", "MINUS",
             "EQUAL", "BRACKETLEFT", "BRACKETRIGHT", "BACKSLASH", "GRAVE"}
KEY_ALIASES = {"ESC": "ESCAPE", "ENTER": "RETURN", "DEL": "DELETE", "PGUP": "PAGE_UP", "PAGEUP": "PAGE_UP",
               "PGDOWN": "PAGE_DOWN", "PAGEDOWN": "PAGE_DOWN", ",": "COMMA", ".": "PERIOD", "/": "SLASH",
               ";": "SEMICOLON", "'": "APOSTROPHE", "-": "MINUS", "=": "EQUAL", "[": "BRACKETLEFT",
               "]": "BRACKETRIGHT", "\\": "BACKSLASH", "`": "GRAVE"}
HYPRCTL_TIMEOUT = 4
BINDS_MAX = 4 * 1024 * 1024


def empty():
    return {"shortcuts": {}, "globalShortcuts": {}, "playbackRate": 1}


# ---------------------------------------------------------------- key combinations for Hyprland

def normalize_combo(value):
    """"super+alt+m" -> "SUPER + ALT + M"; None unless it is modifiers and one known key.
    A global shortcut needs a modifier: a bare key would stop that key typing anywhere."""
    if not isinstance(value, str) or not 0 < len(value) <= 60:
        return None
    tokens = [t.strip() for t in value.split("+")]
    if len(tokens) < 2 or any(not t for t in tokens):
        return None
    mods = set()
    for token in tokens[:-1]:
        mod = MODIFIER_ALIASES.get(token.upper())
        if mod is None or mod in mods:
            return None
        mods.add(mod)
    if not mods & {"SUPER", "CTRL", "ALT"}:   # Shift alone would take capital letters everywhere
        return None
    key = tokens[-1]
    name = KEY_ALIASES.get(key, KEY_ALIASES.get(key.upper(), key.upper()))
    if not (re.fullmatch(r"[A-Z0-9]", name) or re.fullmatch(r"F([1-9]|1[0-9]|2[0-4])", name) or name in KEY_NAMES):
        return None
    return " + ".join([m for m in MODIFIER_ORDER if m in mods] + [name])


def combo_parts(combo):
    """(modifier mask, lower-case key) as `hyprctl binds -j` reports a binding."""
    tokens = [t.strip() for t in combo.split("+")]
    return sum(MODIFIER_BITS[t] for t in tokens[:-1]), tokens[-1].lower()


# ---------------------------------------------------------------- checking and storing

def check(value, strict=True):
    """Settings as the window sends them, checked field by field. Strict: raise ValueError on
    the first problem. Not strict (reading the file): drop what is wrong and keep the rest."""
    out = empty()

    def bad(message):
        if strict:
            raise ValueError(message)

    if not isinstance(value, dict):
        bad("settings must be an object")
        return out
    shortcuts = value.get("shortcuts", {})
    if not isinstance(shortcuts, dict) or len(shortcuts) > ACTIONS_MAX:
        bad(f"shortcuts must be an object of at most {ACTIONS_MAX} actions")
        shortcuts = {}
    for action, keys in shortcuts.items():
        if not isinstance(action, str) or not ACTION_ID.fullmatch(action) or action.startswith("global."):
            bad(f"{str(action)[:60]!r} is not an action")
            continue
        if not isinstance(keys, list) or len(keys) > KEYS_MAX:
            bad(f"{action} takes a list of at most {KEYS_MAX} keys")
            continue
        clean = []
        for key in keys:
            if not isinstance(key, str) or not SEQUENCE.fullmatch(key):
                bad(f"{str(key)[:60]!r} is not a key sequence")
                clean = None
                break
            if key not in clean:
                clean.append(key)
        if clean is not None:
            out["shortcuts"][action] = clean
    globals_ = value.get("globalShortcuts", {})
    if not isinstance(globals_, dict):
        bad("globalShortcuts must be an object")
        globals_ = {}
    seen = set()
    for action, combo in globals_.items():
        if action not in GLOBALS:
            bad(f"{str(action)[:60]!r} is not a global shortcut")
            continue
        if combo in (None, ""):
            continue
        normal = normalize_combo(combo)
        if normal is None:
            bad(f"{str(combo)[:60]!r} is not a key combination with a modifier")
            continue
        if normal in seen:
            bad(f"{normal} is used twice")
            continue
        seen.add(normal)
        out["globalShortcuts"][action] = normal
    rate = value.get("playbackRate", 1)
    if isinstance(rate, bool) or rate not in PLAYBACK_RATES:
        bad("playbackRate is 1, 1.5 or 2")
    else:
        out["playbackRate"] = rate
    return out


def load():
    """The stored settings; empty when there are none, the file is unreadable, or it is not ours."""
    try:
        data = safe.read_json(SETTINGS, SETTINGS_MAX, default=None, **JSON_LIMITS)
    except (safe.UnsafeError, OSError):
        return empty()
    return check(data, strict=False) if data is not None else empty()


def save(settings):
    safe.ensure_dir(CONFIG, 0o700)
    safe.write_json(SETTINGS, settings, mode=0o600)


# ---------------------------------------------------------------- Hyprland

def hyprctl(args):
    return safe.run([str(safe.tool("hyprctl"))] + list(args), timeout=HYPRCTL_TIMEOUT, max_output=BINDS_MAX)


def lua_string(text):
    """A Lua string literal: every byte outside a small safe set is a three-digit decimal escape,
    so no quote, backslash or newline from anywhere can end the string early."""
    out = []
    for byte in text.encode("utf-8"):
        ch = chr(byte)
        out.append(ch if (ch.isascii() and ch.isalnum()) or ch in " +_-./:{}'" else "\\%03d" % byte)
    return '"' + "".join(out) + '"'


def bind_statement(combo, action):
    label, argv = GLOBALS[action]
    command = " ".join(shlex.quote(a) for a in argv)
    return "hl.bind(%s, hl.dsp.exec_cmd(%s), { description = %s })" % (
        lua_string(combo), lua_string(command), lua_string(DESCRIPTION_PREFIX + label))


def unbind_statement(combo):
    return "hl.unbind(%s)" % lua_string(combo)


def current_binds():
    """[(modifier mask, lower-case key, description)] for every binding Hyprland has."""
    r = hyprctl(["binds", "-j"])
    if not r.ok:
        raise safe.UnsafeError("could not read Hyprland's bindings")
    data = safe.loads(r.stdout, max_depth=6, max_items=200000, max_string=4096)
    out = []
    for b in data if isinstance(data, list) else []:
        if isinstance(b, dict) and isinstance(b.get("key"), str) and isinstance(b.get("modmask"), int):
            out.append((b["modmask"], b["key"].lower(), str(b.get("description") or "")))
    return out


def run_lua(statement):
    r = hyprctl(["eval", statement])
    return r.ok and not r.text().strip().startswith("error")


def apply(desired):
    """Make Hyprland's bindings match the global shortcuts you chose. Returns {action: state}:
    "active", "taken" (Hyprland binds it to something else), "failed", or "off"."""
    binds = current_binds()
    ours = {(mask, key): desc for mask, key, desc in binds if desc.startswith(DESCRIPTION_PREFIX)}
    theirs = {(mask, key) for mask, key, desc in binds if not desc.startswith(DESCRIPTION_PREFIX)}
    wanted = {}
    for action, combo in desired.items():
        if action in GLOBALS and normalize_combo(combo) == combo:
            wanted[combo_parts(combo)] = (combo, action, DESCRIPTION_PREFIX + GLOBALS[action][0])
    status = {action: "off" for action in GLOBALS}
    # Ours that nobody wants any more, or that now belong to another action: remove them, but
    # never where a binding of yours shares the keys (unbinding takes every binding on them).
    for part, desc in ours.items():
        if (part not in wanted or wanted[part][2] != desc) and part not in theirs:
            mods = [m for m in MODIFIER_ORDER if part[0] & MODIFIER_BITS[m]]
            run_lua(unbind_statement(" + ".join(mods + [part[1].upper()])))
            ours[part] = None
    for part, (combo, action, desc) in wanted.items():
        if part in theirs:
            status[action] = "taken"
        elif ours.get(part) == desc:
            status[action] = "active"
        else:
            status[action] = "active" if run_lua(bind_statement(combo, action)) else "failed"
    return status
