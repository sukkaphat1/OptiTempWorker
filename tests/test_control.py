from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CONTROL_PATH = ROOT / "linux/overlay/usr/local/lib/opti-temporary-worker/control.py"
SPEC = importlib.util.spec_from_file_location("opti_temporary_control", CONTROL_PATH)
assert SPEC and SPEC.loader
control = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(control)

MANIFEST_PATH = ROOT / "tools/build_release_manifest.py"
MANIFEST_SPEC = importlib.util.spec_from_file_location("opti_release_manifest", MANIFEST_PATH)
assert MANIFEST_SPEC and MANIFEST_SPEC.loader
release_manifest = importlib.util.module_from_spec(MANIFEST_SPEC)
MANIFEST_SPEC.loader.exec_module(release_manifest)


class ArchiveSafetyTests(unittest.TestCase):
    def test_safe_extract_accepts_regular_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            temporary = Path(temporary_name)
            archive = temporary / "worker.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("OptiWorkerSetup/payload/module.py", "VALUE = 1\n")
            destination = temporary / "out"
            destination.mkdir()
            control.safe_extract(archive, destination)
            self.assertEqual(
                (destination / "OptiWorkerSetup/payload/module.py").read_text(encoding="utf-8"),
                "VALUE = 1\n",
            )

    def test_safe_extract_rejects_parent_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            temporary = Path(temporary_name)
            archive = temporary / "worker.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("../../escaped.txt", "no")
            destination = temporary / "out"
            destination.mkdir()
            with self.assertRaisesRegex(control.ControlError, "unsafe update archive path"):
                control.safe_extract(archive, destination)
            self.assertFalse((temporary / "escaped.txt").exists())

    def test_safe_extract_rejects_symbolic_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            temporary = Path(temporary_name)
            archive = temporary / "worker.zip"
            link = zipfile.ZipInfo("OptiWorkerSetup/payload/link")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr(link, "/etc/passwd")
            destination = temporary / "out"
            destination.mkdir()
            with self.assertRaisesRegex(control.ControlError, "symbolic link"):
                control.safe_extract(archive, destination)


class PayloadVerificationTests(unittest.TestCase):
    def make_payload(self, root: Path) -> Path:
        payload = root / "payload"
        (payload / "pkg").mkdir(parents=True)
        content = b"print('verified')\n"
        (payload / "pkg/module.py").write_bytes(content)
        manifest = {
            "format": "opti-worker-package-v1",
            "build_id": "build-123",
            "files": {"pkg/module.py": hashlib.sha256(content).hexdigest()},
        }
        (payload / "worker_manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        return payload

    def test_exact_manifest_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            payload = self.make_payload(Path(temporary_name))
            self.assertEqual(control.verify_payload(payload, "build-123")["build_id"], "build-123")

    def test_unlisted_or_changed_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            payload = self.make_payload(Path(temporary_name))
            (payload / "extra.py").write_text("unexpected\n", encoding="utf-8")
            with self.assertRaisesRegex(control.ControlError, "file set"):
                control.verify_payload(payload, "build-123")
            (payload / "extra.py").unlink()
            (payload / "pkg/module.py").write_text("changed\n", encoding="utf-8")
            with self.assertRaisesRegex(control.ControlError, "manifest hash"):
                control.verify_payload(payload, "build-123")


class ReleaseManifestTests(unittest.TestCase):
    def test_release_manifest_pins_every_install_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            artifacts = Path(temporary_name)
            names = (
                "opti-temporary-worker-rootfs.tar.gz",
                "Install-OptiTemporaryWorker.ps1",
                "Remove-OptiTemporaryWorker.ps1",
            )
            for index, name in enumerate(names):
                (artifacts / name).write_bytes(f"asset-{index}".encode("ascii"))
            previous = sys.argv
            try:
                sys.argv = ["build_release_manifest.py", str(artifacts), "--version", "v-test"]
                self.assertEqual(release_manifest.main(), 0)
            finally:
                sys.argv = previous
            manifest = json.loads((artifacts / "release-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["format"], "opti-temporary-worker-release-v1")
            self.assertEqual(manifest["version"], "v-test")
            for key, name in zip(("rootfs", "bootstrap", "uninstaller"), names, strict=True):
                self.assertEqual(manifest["assets"][key]["name"], name)
                self.assertEqual(manifest["assets"][key]["sha256"], control.sha256(artifacts / name))
            manifest_hash = (artifacts / "release-manifest.json.sha256").read_text(encoding="ascii")
            self.assertTrue(manifest_hash.startswith(control.sha256(artifacts / "release-manifest.json")))


if __name__ == "__main__":
    unittest.main()
