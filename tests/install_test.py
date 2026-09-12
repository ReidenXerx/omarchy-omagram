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


if __name__ == "__main__":
    unittest.main()
