"""Exercise the real launcher with mocked hostname, SSH, and remote execution."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "run_jobs.sh"
REMOTE_PROJECT = "/lustre/cbm/users/dramirez/slurm_scripts_v3"


class RemoteArgumentsTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="cbm-h2-")
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.project = self.root / "local project's files"
        self.project.mkdir()
        self.launcher = self.project / "run_jobs.sh"
        self.launcher.write_bytes(SOURCE.read_bytes())
        self.remote = self.root / "remote project"
        self.remote.mkdir()
        self.capture = self.root / "capture.json"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.receiver = self.root / "receiver.py"
        self.receiver.write_text(
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['H2_CAPTURE']).write_text(json.dumps({"
            "'argv': sys.argv[1:], 'cwd': os.getcwd()}))\n"
            "sys.exit(int(os.environ.get('H2_REMOTE_STATUS', '0')))\n"
        )
        (self.remote / "run_jobs.sh").write_text(
            '"$H2_PYTHON" "$H2_RECEIVER" "./run_jobs.sh" "$@"\n'
        )
        self.command("hostname", "#!/bin/sh\nprintf 'lxi-review\\n'\n")
        self.command(
            "ssh",
            "#!" + sys.executable + "\n"
            "import os, subprocess, sys\n"
            "assert len(sys.argv) == 3, sys.argv\n"
            "shell = '''\n"
            "cd() { command cd \"$H2_REMOTE_DIR\"; }\n"
            "'''\n"
            "sys.exit(subprocess.run(['/bin/sh', '-c', shell + sys.argv[2]]).returncode)\n"
        )
        self.env = os.environ.copy()
        self.env.update(
            PATH=str(self.bin) + os.pathsep + self.env["PATH"],
            H2_CAPTURE=str(self.capture),
            H2_REMOTE_DIR=str(self.remote),
            H2_PYTHON=sys.executable,
            H2_RECEIVER=str(self.receiver),
        )

    def command(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_launcher(self, arguments, cwd=None, env=None, answers="yn"):
        return subprocess.run(
            ["bash", str(self.launcher), *arguments],
            cwd=cwd or self.project,
            env=env or self.env,
            input=answers,
            text=True,
            capture_output=True,
            timeout=5,
        )

    def assert_forwarded(self, arguments, expected, cwd=None):
        result = self.run_launcher(arguments, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads(self.capture.read_text())
        self.assertEqual(captured["argv"], ["./run_jobs.sh", *expected])
        self.assertEqual(captured["cwd"], str(self.remote))
        self.assertFalse((self.remote / "h2_injected").exists())

    def test_flags_and_range_without_explicit_config(self):
        args = ["-t", "--digitization", "--qa", "--test", "-j", "1,3,7-10"]
        self.assert_forwarded(args, args)

    def test_no_arguments_does_not_add_a_config(self):
        self.assert_forwarded([], [])

    def test_config_basename_resolves_to_config_directory(self):
        config_dir = self.project / "config"
        config_dir.mkdir()
        (config_dir / "test_config.yaml").write_text("run: fixture\n")
        args = ["test_config.yaml"]
        expected = [REMOTE_PROJECT + "/config/test_config.yaml"]
        self.assert_forwarded(args, expected)

    def test_project_config_between_options_preserves_order(self):
        args = ["--transport", "test.yaml", "-j", "1-5", "--test"]
        expected = ["--transport", REMOTE_PROJECT + "/test.yaml", "-j", "1-5", "--test"]
        self.assert_forwarded(args, expected)

    def test_config_and_range_with_the_same_value(self):
        self.assert_forwarded(["-j", "1", "1"], ["-j", "1", REMOTE_PROJECT + "/1"])

    def test_absolute_project_config_is_relocated(self):
        args = [str(self.project / "test.yaml"), "-r"]
        self.assert_forwarded(args, [REMOTE_PROJECT + "/test.yaml", "-r"])

    def test_relative_config_from_another_working_directory(self):
        args = [self.project.name + "/test.yaml", "--transport"]
        expected = [REMOTE_PROJECT + "/test.yaml", "--transport"]
        self.assert_forwarded(args, expected, cwd=self.root)

    def test_nested_config_and_shell_metacharacters(self):
        subdir = self.project / "configs with spaces"
        subdir.mkdir()
        name = "run 'quoted' \"double\" $(touch h2_injected) `touch h2_injected` \\ *.yaml"
        args = ["configs with spaces/" + name, "-t", "-j", "1,3"]
        expected = [REMOTE_PROJECT + "/configs with spaces/" + name, "-t", "-j", "1,3"]
        self.assert_forwarded(args, expected)

    def test_filename_with_a_trailing_newline_is_preserved(self):
        name = "run.yaml\n"
        self.assert_forwarded([name, "-t"], [REMOTE_PROJECT + "/" + name, "-t"])

    def test_empty_option_value_is_forwarded_unchanged(self):
        # Task-range semantics are validated by the destination launcher.
        self.assert_forwarded(["-t", "-j", ""], ["-t", "-j", ""])

    def test_arguments_survive_optional_sync(self):
        sync = SOURCE.parent / "utils/sync.sh"
        (self.project / "utils").mkdir()
        (self.project / "utils/sync.sh").write_bytes(sync.read_bytes())
        (self.project / "utils/sync.sh").chmod(0o755)
        self.command("rsync", "#!/bin/sh\nexit 0\n")
        args = ["test.yaml", "-t", "--test", "-j", "1,3"]
        result = self.run_launcher(args, answers="yy")
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads(self.capture.read_text())
        expected = ["./run_jobs.sh", REMOTE_PROJECT + "/test.yaml", *args[1:]]
        self.assertEqual(captured["argv"], expected)

    def test_declined_remote_execution_does_not_connect(self):
        result = self.run_launcher(["-t"], answers="n")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.capture.exists())

    def test_absolute_external_config_is_preserved(self):
        args = ["/shared/config 'remote'.yaml", "-d"]
        self.assert_forwarded(args, args)

    def test_relative_config_outside_project_is_rejected(self):
        result = self.run_launcher(["external.yaml", "-t"], cwd=self.root)
        self.assertEqual(result.returncode, 2)
        self.assertIn("absolute path on the submission host", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_missing_relative_parent_is_rejected(self):
        result = self.run_launcher(["missing/config.yaml", "-t"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("configuration directory", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_remote_failure_is_propagated(self):
        env = self.env.copy()
        env["H2_REMOTE_STATUS"] = "37"
        result = self.run_launcher(["-t"], env=env)
        self.assertEqual(result.returncode, 37)

    def test_help_does_not_connect(self):
        result = self.run_launcher(["--help"])
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)
        self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main()
