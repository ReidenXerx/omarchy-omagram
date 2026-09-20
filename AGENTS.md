# Repository Guidelines

## Project Structure & Module Organization

Omagram is an Omarchy plugin built from QML, Python, and plain JavaScript.

- `app/` contains the full application UI. Reusable display logic lives in `app/Model.js`, shortcut logic in `app/Keymap.js`, and QML files define views and controls.
- `shell/` provides Omarchy integration: the background service, bar widget, quick view, and overlay.
- `bin/` contains Python helpers for TDLib, media, notifications, settings, installation, and startup.
- `tests/` holds dependency-light Python `unittest` files and Node.js tests for pure JavaScript logic.
- `assets/`, `manifest.json`, and `menu.jsonc` contain branding and plugin metadata.

Keep UI-independent behavior in Python or JavaScript so it can be tested without a compositor.

## Build, Test, and Development Commands

Run commands from the repository root:

```bash
bin/omagram-build-tdlib          # build the pinned TDLib into user data
bin/omagram-build-tdlib --check  # verify that a usable library is installed
python3 -m unittest discover -s tests -p '*_test.py'
node tests/model-test.js
node tests/keymap-test.js
/usr/bin/python3 bin/omagram     # launch or focus the application
```

Python tests use fakes and temporary runtime directories; they must not contact Telegram or alter the live Hyprland configuration.

## Coding Style & Naming Conventions

Follow nearby code rather than introducing a new toolchain. Use four-space indentation in Python and two spaces in QML/JavaScript. Python names use `snake_case`; QML components use `PascalCase.qml`; JavaScript functions use `camelCase`. Keep script shebangs intact. Prefer explicit argument lists and absolute helper paths over shell invocation. Treat Telegram text, paths, and IPC payloads as untrusted; preserve existing validation.

## Testing Guidelines

Add focused regression tests beside the affected layer. Name Python tests `*_test.py`, methods `test_<behavior>`, and JavaScript cases with a behavioral sentence. Run all Python and Node suites before submitting. There is no numeric coverage gate; cover malformed input, safety boundaries, and failure paths.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects without conventional-commit prefixes, for example `Show Omagram in the app launcher`. Keep each commit focused. Pull requests should explain user-visible behavior, list tests run, link issues, and include a screenshot or recording for UI changes. Call out changes to permissions, secrets, IPC, TDLib, or generated user files.

## Security & Configuration

Never commit Telegram API credentials, session data, keyring values, or files from `~/.local/share/omagram`. Preserve the rule that secrets do not enter files, command lines, or logs. Avoid modifying unrelated user configuration during development or tests.
