#!/usr/bin/env python3
"""Signatur-, Archiv- und Installationsgrenzen ohne echte Benutzerinstallation."""

import base64
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

sys.path.insert(0, str(Path(__file__).parents[1]))
from vicious_sid.update import Updater, UpdateError, REPOSITORY


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vicious-update-test-")
        self.root = Path(self.temporary.name).resolve()
        self.prefix = self.root / "prefix"
        self.install_root = self.prefix / "share/vicious-sid-player"
        self.bundle = self.install_root / "versions/1.0.0-fixture"
        self.bundle.mkdir(parents=True)
        self.current = self.install_root / "current"
        self.current.symlink_to(self.bundle.relative_to(self.install_root))
        (self.bundle / "VERSION").write_text("1.0.0\n")
        self.key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(self.key.public_key().public_bytes_raw()) + b"\n"
        (self.bundle / "update-public-key.txt").write_bytes(self.public)
        self.updater = Updater(self.bundle)
        self.data = dict(schema=1, product="vicious-sid-player", arch="x86_64", version="1.0.1",
                         url=f"https://github.com/{REPOSITORY}/releases/download/v1.0.1/vicious-sid-player-1.0.1-linux-x86_64.tar.gz",
                         sha256="0" * 64, size=100, notes="Reference release")
        self.machine = patch("vicious_sid.update.platform.machine", return_value="x86_64")
        self.machine.start()

    def tearDown(self):
        self.machine.stop()
        self.temporary.cleanup()

    def signed(self, data=None):
        raw = json.dumps(data or self.data).encode()
        return raw, base64.b64encode(self.key.sign(raw))

    def test_signature_and_newer_version(self):
        raw, signature = self.signed()
        self.assertEqual(self.updater.verify_manifest(raw, signature), self.data)
        for payload, sig in [(raw + b" ", signature), (raw, b"invalid"),
                             (raw, base64.b64encode(Ed25519PrivateKey.generate().sign(raw)))]:
            with self.assertRaises(UpdateError):
                self.updater.verify_manifest(payload, sig)
        with patch.object(self.updater, "fetch_manifest", return_value=self.data):
            self.assertEqual(self.updater.check(), self.data)
            (self.bundle / "VERSION").write_text("1.0.1\n")
            self.assertIsNone(self.updater.check())

    def test_signed_wrong_platform_source_and_invalid_metadata(self):
        for key, value in [("product", "another-app"), ("arch", "aarch64"),
                           ("url", "https://example.com/archive"), ("size", True),
                           ("size", 2 ** 40), ("sha256", "invalid"),
                           ("version", "1.0.1-rc"), ("notes", ["wrong type"])]:
            with self.subTest(key=key, value=value), self.assertRaises(UpdateError):
                self.updater.verify_manifest(*self.signed(dict(self.data, **{key: value})))

    def archive(self, entries):
        target = self.root / "fixture.tar.gz"
        with tarfile.open(target, "w:gz") as archive:
            for name, content, kind in entries:
                info = tarfile.TarInfo(name)
                info.type = kind
                info.mode = 0o755 if name.endswith("desktop-engine") else 0o644
                info.size = len(content)
                info.linkname = "/tmp/outside"
                archive.addfile(info, io.BytesIO(content))
        return target

    def test_traversal_links_devices_and_duplicate_paths_rejected(self):
        for name, kind in [("../outside", tarfile.REGTYPE),
                           ("vicious-sid-player-linux/../../outside", tarfile.REGTYPE),
                           ("/absolute", tarfile.REGTYPE),
                           ("vicious-sid-player-linux/link", tarfile.SYMTYPE),
                           ("vicious-sid-player-linux/hardlink", tarfile.LNKTYPE),
                           ("vicious-sid-player-linux/fifo", tarfile.FIFOTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as output:
                with self.assertRaises(UpdateError):
                    self.updater.extract(self.archive([(name, b"", kind)]), Path(output))
        repeated = [("vicious-sid-player-linux/file", b"x", tarfile.REGTYPE)] * 2
        with self.assertRaises(UpdateError):
            self.updater.extract(self.archive(repeated), self.root / "duplicates")

    def test_inactive_installation_and_lock_are_rejected(self):
        self.current.unlink()
        with self.assertRaises(UpdateError):
            self.updater.install(self.data)
        self.current.symlink_to(self.bundle.relative_to(self.install_root))
        with (self.install_root / ".update-lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(UpdateError):
                self.updater.install(self.data)

    def test_changed_offer_failed_download_and_cancellation_preserve_current(self):
        with patch.object(self.updater, "check", return_value=dict(self.data, sha256="1" * 64)):
            with self.assertRaises(UpdateError):
                self.updater.install(self.data)
        with patch.object(self.updater, "check", return_value=self.data), \
                patch.object(self.updater, "download", side_effect=OSError("fixture")):
            with self.assertRaises(OSError):
                self.updater.install(self.data)
        cancelled = Updater(self.bundle, cancel=lambda: True)
        with self.assertRaises(UpdateError):
            cancelled.check_cancelled()
        self.assertEqual(self.current.resolve(), self.bundle)

    def test_complete_authenticated_install_and_digest_failure(self):
        archive = self.archive([
            ("vicious-sid-player-linux/VERSION", b"1.0.1\n", tarfile.REGTYPE),
            ("vicious-sid-player-linux/update-public-key.txt", self.public, tarfile.REGTYPE),
            ("vicious-sid-player-linux/bin/vicious-sid-desktop-engine",
             b'#!/bin/sh\nprintf \'%s\\n\' \'{"event":"ready"}\'\n', tarfile.REGTYPE),
        ])
        data = dict(self.data, size=archive.stat().st_size,
                    sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        # Kleiner eigener Installer als Nachweis, dass ausschließlich der alte
        # lokale Installer mit genau dem verifizierten Paket aufgerufen wird.
        (self.bundle / "install.py").write_text('''from pathlib import Path
def install(source, prefix):
    assert (source / 'VERSION').read_text().strip() == '1.0.1'
    root = prefix / 'share/vicious-sid-player'
    target = root / 'versions/1.0.1-fixture'
    target.mkdir()
    replacement = root / '.current-fixture'
    replacement.symlink_to(target.relative_to(root))
    replacement.replace(root / 'current')
''')

        def download(url, destination, limit):
            Path(destination).write_bytes(archive.read_bytes())
            return archive.stat().st_size

        with patch.object(self.updater, "check", return_value=data), \
                patch.object(self.updater, "download", side_effect=download):
            with patch.dict(data, sha256="0" * 64):
                with self.assertRaises(UpdateError):
                    self.updater.install(data)
                self.assertEqual(self.current.resolve(), self.bundle)
            self.assertEqual(self.updater.install(data), "1.0.1")
            self.assertEqual(self.current.resolve().name, "1.0.1-fixture")
            self.assertTrue(self.bundle.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
