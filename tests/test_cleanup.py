"""Validate safe cleanup and debug preservation of remote run snapshots."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "sbash/cleanup.sbash"


class CleanupTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="cbm-cleanup-")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name) / "runs"
        self.snapshot = self.root / "run-1"
        self.snapshot.mkdir(parents=True)
        (self.snapshot / "marker").write_text("snapshot")
        self.env = os.environ.copy()
        self.env.update(
            CBM_RUN_SNAPSHOT_ROOT=str(self.root),
            CBM_RUN_SNAPSHOT_DIR=str(self.snapshot),
        )

    def run_cleanup(self, *options, env=None):
        return subprocess.run(
            ["bash", str(SCRIPT), *options],
            env=env or self.env, text=True, capture_output=True, timeout=5,
        )

    def test_cleanup_removes_snapshot(self):
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.snapshot.exists())
        self.assertTrue(self.root.exists())

    def test_debug_preserves_snapshot(self):
        result = self.run_cleanup("--debug")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.snapshot.is_dir())
        self.assertIn("preserving run snapshot", result.stdout)

    def test_cleanup_refuses_snapshot_root(self):
        env = self.env.copy()
        env["CBM_RUN_SNAPSHOT_DIR"] = str(self.root)
        result = self.run_cleanup(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.root.is_dir())
        self.assertIn("Refusing to clean unsafe", result.stderr)

    def test_cleanup_refuses_unrelated_directory(self):
        unrelated = Path(self.root.parent) / "unrelated"
        unrelated.mkdir()
        env = self.env.copy()
        env["CBM_RUN_SNAPSHOT_DIR"] = str(unrelated)
        result = self.run_cleanup(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(unrelated.is_dir())


if __name__ == "__main__":
    unittest.main()
