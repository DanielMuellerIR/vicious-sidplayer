#!/usr/bin/env python3
"""Installationsfehler dürfen keinen Starter oder alten Stand beschädigen."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "installer", Path(__file__).parents[1] / "install.py"
)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vicious-install-tests-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.prefix = self.root / "prefix"
        for name, data in [
            ("vicious-sid-player", b"#!/bin/sh\nexit 0\n"),
            ("bin/vicious-sid-desktop-engine", b"\x7fELFfixture"),
            ("VERSION", b"1.9.52\n"),
            ("ui/vicious_sid/app.py", b"# fixture\n"),
            ("resources/AppIcon.png", b"icon"),
        ]:
            target = self.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (self.source / "vicious-sid-player").chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def run_install(self, fail=False):
        def run(command, **kwargs):
            if fail and command[0] == "update-desktop-database":
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)

        with (
            patch.object(installer.subprocess, "run", side_effect=run),
            patch.object(
                installer.shutil,
                "which",
                return_value="/fixture/update-desktop-database",
            ),
        ):
            installer.install(self.source, self.prefix)

    def test_first_install_failure_removes_activated_files(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_install(fail=True)
        for name in [
            "share/vicious-sid-player/current",
            "bin/vicious-sid-player",
            "share/applications/vicious-sid-player.desktop",
            "share/icons/hicolor/1024x1024/apps/vicious-sid-player.png",
        ]:
            item = self.prefix / name
            self.assertFalse(item.exists() or item.is_symlink(), name)

    def test_failed_upgrade_restores_previous_version_and_desktop_entry(self):
        self.run_install()
        current = self.prefix / "share/vicious-sid-player/current"
        previous = current.readlink()
        desktop = self.prefix / "share/applications/vicious-sid-player.desktop"
        desktop.write_text("custom previous entry")
        (self.source / "VERSION").write_text("1.9.53\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_install(fail=True)
        self.assertEqual(current.readlink(), previous)
        self.assertEqual(desktop.read_text(), "custom previous entry")
        self.assertTrue((self.prefix / "bin/vicious-sid-player").is_file())

    def test_foreign_launcher_is_untouched(self):
        launcher = self.prefix / "bin/vicious-sid-player"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("foreign launcher")
        with self.assertRaises(ValueError):
            self.run_install()
        self.assertEqual(launcher.read_text(), "foreign launcher")
        self.assertFalse(
            (self.prefix / "share/vicious-sid-player/current").is_symlink()
        )

    def test_successful_install_registers_file_and_url_associations(self):
        self.run_install()
        current = self.prefix / "share/vicious-sid-player/current"
        self.assertEqual((current / "VERSION").read_text(), "1.9.52\n")
        desktop = (
            self.prefix / "share/applications/vicious-sid-player.desktop"
        ).read_text()
        self.assertIn("Terminal=false", desktop)
        self.assertIn("x-scheme-handler/vicioussid", desktop)
        self.run_install()
        self.assertEqual(len(list((current.parent / "versions").iterdir())), 1)

    def test_installed_launcher_resolves_active_version(self):
        launcher = Path(__file__).parents[1] / "vicious-sid-player"
        (self.source / "vicious-sid-player").write_bytes(launcher.read_bytes())
        (self.source / "ui/vicious_sid/app.py").write_text(
            "import json, sys\nprint(json.dumps(sys.argv[1:]))\n"
        )
        self.run_install()
        result = subprocess.run(
            [str(self.prefix / "bin/vicious-sid-player"), "--support-dir", "fixture"],
            capture_output=True, text=True, check=True,
        )
        arguments = json.loads(result.stdout)
        self.assertEqual(arguments[0], "--engine")
        self.assertEqual(Path(arguments[1]).read_bytes(), b"\x7fELFfixture")
        self.assertEqual(arguments[2:], ["--support-dir", "fixture"])


if __name__ == "__main__":
    unittest.main()
