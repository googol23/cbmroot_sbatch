"""H6 regression tests. Run with python3 -m unittest discover -s tests -v."""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

import yaml


PROJECT = Path(__file__).resolve().parents[1]


class PipelineTestMode(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="cbm-h6-")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name)
        self.config = yaml.safe_load((PROJECT / "default_config.yaml").read_text())
        self.config["run"].update(
            pipeline_test=False,
            task_range="1",
            cbmroot_setup=str(self.root / "missing-setup.sh"),
            input_dir=str(self.root / "input"),
            output_dir=str(self.root / "output"),
            log_dir=str(self.root / "logs"),
        )
        self.config_path = self.root / "run config.yaml"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        for name in list(self.env):
            if name.startswith(("SLURM_", "CFG_", "CBM_")):
                self.env.pop(name)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.command("sleep", "exit 0")

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def write_config(self):
        self.config_path.write_text(yaml.safe_dump(self.config))

    def load_config(self, *options):
        self.write_config()
        return subprocess.run(
            [sys.executable, str(PROJECT / "config_loader.py"),
             str(self.config_path), *options],
            env=self.env, text=True, capture_output=True, timeout=5,
        )

    def assert_test_settings(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = dict(line.split("\t", 1) for line in result.stdout.splitlines())
        self.assertEqual(settings["CFG_PIPELINE_TEST"], "true")
        for key in ("CFG_RUN_CONFIG", "CFG_TRA_CONFIG",
                    "CFG_RAW_CONFIG", "CFG_REC_CONFIG"):
            self.assertTrue(Path(settings[key]).is_file(), key)
        self.assertFalse(Path(self.config["run"]["cbmroot_setup"]).exists())

    def run_job(self, job_id="local_test", task_id="3"):
        env = self.env.copy()
        if job_id is not None:
            env["SLURM_JOB_ID"] = job_id
        if task_id is not None:
            env["SLURM_ARRAY_TASK_ID"] = task_id
        return subprocess.run(
            ["bash", str(PROJECT / "success.sbash")],
            env=env, text=True, capture_output=True, timeout=5,
        )

    def test_normal_mode_rejects_missing_setup(self):
        result = self.load_config()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("setup file does not exist", result.stderr)

    def test_normal_mode_accepts_existing_setup(self):
        setup = self.root / "setup.sh"
        setup.write_text(":\n")
        self.config["run"]["cbmroot_setup"] = str(setup)
        result = self.load_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CFG_PIPELINE_TEST\tfalse\n", result.stdout)

    def test_yaml_test_mode_does_not_require_setup(self):
        self.config["run"]["pipeline_test"] = True
        self.assert_test_settings(self.load_config())

    def test_cli_test_mode_overrides_yaml_false(self):
        self.assert_test_settings(self.load_config("--test"))

    def test_cli_and_yaml_test_mode_agree(self):
        self.config["run"]["pipeline_test"] = True
        self.assert_test_settings(self.load_config("--test"))

    def test_cli_test_mode_still_rejects_invalid_yaml_boolean(self):
        self.config["run"]["pipeline_test"] = "invalid"
        result = self.load_config("--test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pipeline_test must be true or false", result.stderr)

    def test_test_mode_still_rejects_invalid_event_count(self):
        self.config["run"]["nevents"] = 0
        result = self.load_config("--test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nevents must be a positive integer", result.stderr)

    def test_test_mode_still_rejects_empty_stage_config(self):
        self.config["transport"] = {}
        result = self.load_config("--test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("transport must be a nonempty YAML mapping", result.stderr)

    def test_local_job_succeeds_without_cbmroot_configuration(self):
        result = self.run_job()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("Pipeline test completed: job=local_test task=3", result.stdout)

    def test_slurm_array_job_succeeds(self):
        result = self.run_job(job_id="12345", task_id="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Pipeline test completed: job=12345 task=7", result.stdout)

    def test_non_array_qa_job_succeeds(self):
        result = self.run_job(job_id="12345", task_id=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Pipeline test completed: job=12345 task=batch", result.stdout)

    def test_missing_job_id_fails_before_completion(self):
        result = self.run_job(job_id=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run through Slurm or run_jobs.sh --local", result.stderr)
        self.assertNotIn("Pipeline test completed:", result.stdout)

    def test_empty_job_id_fails_before_completion(self):
        result = self.run_job(job_id="")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Pipeline test completed:", result.stdout)

    def test_failed_work_is_not_reported_as_success(self):
        self.command("sleep", "exit 17")
        result = self.run_job()
        self.assertEqual(result.returncode, 17)
        self.assertIn("Pipeline test started:", result.stdout)
        self.assertNotIn("Pipeline test completed:", result.stdout)

    def test_launcher_passes_cli_test_override_before_validation(self):
        self.write_config()
        # Run the launcher's configuration-loading block unchanged. Host routing
        # and the known H1 exit on master are outside this H6 regression test.
        source = (PROJECT / "run_jobs.sh").read_text()
        start = source.index("explicit_config=false")
        end = source.index("# Select pipeline stages", start)
        loading = source[start:end]
        script = "\n".join([
            "set -euo pipefail",
            "SCRIPT_DIR=" + shlex.quote(str(PROJECT)),
            "config_file=" + shlex.quote(str(self.config_path)),
            "test_override=true",
            loading,
            'printf "RESULT=%s\\n" "$CFG_PIPELINE_TEST"',
        ])
        # Use the interpreter running these tests even when python3 on PATH differs.
        python = self.bin / "python3"
        python.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + ' "$@"\n')
        python.chmod(0o755)
        result = subprocess.run(
            ["bash", "-s"], input=script, env=self.env,
            text=True, capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT=true\n", result.stdout)


if __name__ == "__main__":
    unittest.main()
