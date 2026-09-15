#!/usr/bin/python3
"""python3 tests/install_test.py -- what goes into the Omarchy menu, the window's runtime root and
the TDLib build log, in a sandbox under $XDG_RUNTIME_DIR."""
import importlib.machinery
import importlib.util
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"
sys.dont_write_bytecode = True
sys.path.insert(0, str(BIN))
import plugin_safety as safe  # noqa: E402


def load(name):
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), str(BIN / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="omagram-install-", dir=safe.runtime_dir()))
        os.chmod(self.root, 0o700)
        self.addCleanup(shutil.rmtree, self.root, True)

    def patch(self, target, name, value):
        patch = mock.patch.object(target, name, value)
        patch.start()
        self.addCleanup(patch.stop)


class MenuInstall(Sandbox):
    def plugin(self, dirname):
        plugin = self.root / dirname
        (plugin / "bin").mkdir(parents=True)
        launcher = plugin / "bin" / "omagram"
        launcher.write_text("#!/usr/bin/python3\n")
        os.chmod(launcher, 0o755)
        return plugin

    def test_the_plugin_path_goes_into_menu_commands_only_when_plain(self):
        installer = load("omagram-menu-install")
        plugin = self.plugin("reidenxerx.omagram")
        self.patch(installer, "PLUGIN_DIR", plugin)
        self.assertEqual(installer.plugin_bin(), str(plugin / "bin"))
        for bad in ("with space", "semi;colon", "dollar$(x)", "quote'd", "back`tick"):
            with mock.patch.object(installer, "PLUGIN_DIR", self.plugin(bad)):
                with self.assertRaises(safe.UnsafeError, msg=bad):
                    installer.plugin_bin()

    def test_a_launcher_others_can_write_is_not_put_in_the_menu(self):
        installer = load("omagram-menu-install")
        plugin = self.plugin("writable")
        os.chmod(plugin / "bin" / "omagram", 0o777)
        self.patch(installer, "PLUGIN_DIR", plugin)
        with self.assertRaises(safe.UnsafeError):
            installer.plugin_bin()


class RuntimeRoot(Sandbox):
    def setUp(self):
        super().setUp()
        self.launcher = load("omagram")
        self.shell = self.root / "omarchy-shell"
        for name in ("Commons", "Ui"):
            (self.shell / name).mkdir(parents=True)
        self.app_root = self.root / "run" / "app"
        self.patch(self.launcher, "APP_ROOT", self.app_root)
        self.patch(self.launcher, "omarchy_shell", lambda: self.shell)

    def test_links_and_the_shell_file_are_made_and_kept(self):
        self.launcher.prepare_root()
        self.launcher.prepare_root()   # the next start finds everything in place
        self.assertEqual(os.readlink(self.app_root / "App"), str(self.launcher.PLUGIN / "app"))
        self.assertEqual(os.readlink(self.app_root / "Commons"), str(self.shell / "Commons"))
        self.assertIn("App.Main", (self.app_root / "shell.qml").read_text())

    def test_a_planted_file_or_a_symlinked_directory_stops_it(self):
        self.app_root.mkdir(parents=True, mode=0o700)
        (self.app_root / "App").write_text("not a link")
        with self.assertRaises(safe.UnsafeError):
            self.launcher.prepare_root()
        shutil.rmtree(self.root / "run")
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir(mode=0o700)
        (self.root / "run").symlink_to(elsewhere)
        with self.assertRaises(safe.UnsafeError):
            self.launcher.prepare_root()
        self.assertEqual(list(elsewhere.iterdir()), [], "nothing is made through the link")


class BuildLog(Sandbox):
    def test_the_build_log_keeps_only_its_end(self):
        build = load("omagram-build-tdlib")
        log = self.root / "build.log"
        self.patch(build, "LOG", log)
        self.patch(build, "LOG_MAX", 1000)
        output = safe.Result(0, b"x" * 700, b"", False, False)
        self.patch(build.safe, "run", lambda *args, **kwargs: output)
        build.run_logged(["cmake", "--build", "."], 10)
        build.run_logged(["cmake", "--build", "."], 10)
        data = log.read_bytes()
        self.assertEqual(len(data), 1000)
        self.assertTrue(data.endswith(b"x" * 700))


class DesktopEntry(Sandbox):
    """Omagram's entry in the app launcher: ~/.local/share/applications/omagram.desktop."""

    def make_plugin(self, where):
        (where / "bin").mkdir(parents=True)
        (where / "assets").mkdir()
        launcher = where / "bin" / "omagram"
        launcher.write_text("#!/usr/bin/python3\n")
        os.chmod(launcher, 0o755)
        (where / "assets" / "omagram.svg").write_text("<svg/>\n")
        return where

    def setUp(self):
        super().setUp()
        self.launcher = load("omagram")
        self.plugin = self.make_plugin(self.root / "plugins" / "reidenxerx.omagram")
        self.apps = self.root / "share" / "applications"
        self.entry = self.apps / "omagram.desktop"
        self.patch(self.launcher, "PLUGIN", self.plugin)
        self.patch(self.launcher, "applications_dir", lambda: self.apps)

    def fields(self):
        return dict(line.split("=", 1) for line in self.entry.read_text().splitlines() if "=" in line)

    def test_the_entry_opens_this_copy_of_the_plugin(self):
        self.assertEqual(self.launcher.install_desktop_entry(), "written")
        fields = self.fields()
        self.assertEqual(fields["Name"], "Omagram")
        self.assertEqual(fields["Exec"], f"/usr/bin/python3 {self.plugin}/bin/omagram")
        self.assertEqual(fields["TryExec"], f"{self.plugin}/bin/omagram")
        self.assertEqual(fields["Icon"], f"{self.plugin}/assets/omagram.svg")
        self.assertEqual(fields["StartupWMClass"], "omagram")
        self.assertEqual(fields["X-Omagram-Managed"], "reidenxerx.omagram")
        self.assertEqual(self.entry.stat().st_mode & 0o777, 0o644)

    def test_telegram_is_named_only_as_an_unofficial_client(self):
        self.launcher.install_desktop_entry()
        fields = self.fields()
        self.assertNotIn("Telegram", fields["Name"])
        for key in ("GenericName", "Comment"):
            self.assertEqual(fields[key].count("Telegram"), fields[key].count("Unofficial Telegram"), key)

    def test_the_next_start_leaves_an_up_to_date_entry_alone(self):
        self.launcher.install_desktop_entry()
        before = self.entry.stat()
        self.assertEqual(self.launcher.install_desktop_entry(), "unchanged")
        after = self.entry.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_an_entry_for_an_older_copy_is_brought_up_to_date(self):
        self.launcher.install_desktop_entry()
        self.entry.write_text(self.entry.read_text().replace(str(self.plugin), "/old/place"))
        self.assertEqual(self.launcher.install_desktop_entry(), "written")
        self.assertNotIn("/old/place", self.entry.read_text())

    def test_hiding_it_from_the_launcher_is_kept(self):
        self.launcher.install_desktop_entry()
        self.entry.write_text(self.entry.read_text().replace("[Desktop Entry]\n", "[Desktop Entry]\nNoDisplay = true\n"))
        self.assertEqual(self.launcher.install_desktop_entry(), "written")
        self.assertEqual(self.fields()["NoDisplay"], "true")
        self.assertEqual(self.launcher.install_desktop_entry(), "unchanged")

    def test_a_file_omagram_did_not_write_is_never_touched(self):
        self.apps.mkdir(parents=True)
        mine = "[Desktop Entry]\nType=Application\nName=Someone else\nExec=/usr/bin/true\n"
        self.entry.write_text(mine)
        self.assertEqual(self.launcher.install_desktop_entry(), "foreign")
        self.assertEqual(self.entry.read_text(), mine)
        # the mark counts only inside the [Desktop Entry] group
        self.entry.write_text(mine + "[Desktop Action x]\nX-Omagram-Managed=reidenxerx.omagram\n")
        self.assertEqual(self.launcher.install_desktop_entry(), "foreign")

    def test_a_symlink_or_an_oversized_file_is_not_written_through(self):
        self.apps.mkdir(parents=True)
        target = self.root / "target"
        target.write_text("keep")
        self.entry.symlink_to(target)
        with self.assertRaises(safe.UnsafeError):
            self.launcher.install_desktop_entry()
        self.assertEqual(target.read_text(), "keep")
        self.entry.unlink()
        huge = b"[Desktop Entry]\nX-Omagram-Managed=reidenxerx.omagram\n" + b"#" * self.launcher.DESKTOP_MAX
        self.entry.write_bytes(huge)
        self.assertEqual(self.launcher.install_desktop_entry(), "foreign")
        self.assertEqual(self.entry.read_bytes(), huge)

    def test_a_plugin_path_that_would_need_quoting_gets_no_entry(self):
        odd = self.make_plugin(self.root / "with space" / "reidenxerx.omagram")
        with mock.patch.object(self.launcher, "PLUGIN", odd):
            self.assertEqual(self.launcher.install_desktop_entry(), "skipped")
        self.assertFalse(self.entry.exists())

    def test_the_applications_folder_follows_xdg_data_home(self):
        fresh = load("omagram")
        with mock.patch.dict(os.environ, {"XDG_DATA_HOME": "/somewhere/data"}):
            self.assertEqual(fresh.applications_dir(), pathlib.Path("/somewhere/data/applications"))
        with mock.patch.dict(os.environ, {"XDG_DATA_HOME": "relative/data"}):
            self.assertEqual(fresh.applications_dir(), pathlib.Path(safe.home_dir()) / ".local/share/applications")

    def test_the_entry_passes_desktop_file_validate(self):
        if not safe.has_tool("desktop-file-validate"):
            self.skipTest("desktop-file-validate is not installed")
        self.launcher.install_desktop_entry()
        result = safe.run(["desktop-file-validate", str(self.entry)], timeout=10, max_output=65536)
        report = result.text() + result.stderr.decode("utf-8", "replace")
        self.assertTrue(result.ok, report)
        self.assertNotIn("error", report.lower(), report)

    def test_the_shell_service_refreshes_it_when_it_starts(self):
        self.assertIn('service.binDir + "omagram", "--desktop-entry"]', (ROOT / "shell" / "Service.qml").read_text())


if __name__ == "__main__":
    unittest.main()
