"""H7: preparation and logging failures must stop the real stage scripts."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
STAGES = {
    "transport": ("run_tra.sbash", "tra", "transport.log"),
    "digitization": ("run_raw.sbash", "raw", "digitization.log"),
    "reconstruction": ("run_rec.sbash", "rec", "reconstruction.log"),
}


class StageFailureTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="cbm-h7-")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name)
        self.project = self.root / "pipeline scripts"
        self.project.mkdir()
        (self.project / "sbash").mkdir()
        shutil.copy2(PROJECT / "run_common.sh", self.project / "run_common.sh")
        for name in (item[0] for item in STAGES.values()):
            shutil.copy2(PROJECT / "sbash" / name, self.project / "sbash" / name)
        self.install = self.root / "CBMROOT install"
        self.vmc = self.install / "share" / "cbmroot"
        self.vmc.mkdir(parents=True)
        binaries = self.install / "bin"
        binaries.mkdir()
        self.trace = self.root / "invocations.jsonl"
        for name in ("cbmsim_transport", "cbmsim_digitization", "cbmreco_offline"):
            path = binaries / name
            path.write_text(
                "#!" + sys.executable + "\n"
                "import json, os, pathlib, sys\n"
                "with open(os.environ['H7_TRACE'], 'a') as trace:\n"
                "    trace.write(json.dumps(sys.argv) + '\\n')\n"
                "print('FAKE_PROCESSING_OUTPUT')\n"
                "sys.exit(int(os.environ.get('H7_BINARY_STATUS', '0')))\n"
            )
            path.chmod(0o755)
        self.setup = self.root / "setup.sh"
        self.setup.write_text("export VMCWORKDIR=" + shlex.quote(str(self.vmc)) + "\n")
        self.output = self.root / "output with spaces"
        self.input = self.root / "input with spaces"
        self.input.mkdir()
        (self.input / "dcmqgsm_1.root").write_text("input fixture")
        for stage in ("tra", "raw", "rec"):
            (self.output / stage / "1").mkdir(parents=True)
        (self.output / "tra/1/1.tra.root").write_text("transport fixture")
        (self.output / "tra/1/1.par.root").write_text("parameter fixture")
        (self.output / "raw/1/1.digi.root").write_text("digitization fixture")
        (self.output / "raw/1/1.par.root").write_text("parameter fixture")
        self.bin = self.root / "commands"
        self.bin.mkdir()
        self.command("root", "exit 0")
        self.env = os.environ.copy()
        for name in list(self.env):
            if name.startswith(("CFG_", "SLURM_", "CBM_")) or name == "VMCWORKDIR":
                self.env.pop(name)
        self.env.update(
            PATH=str(self.bin) + os.pathsep + self.env["PATH"],
            CBM_RUN_DIR=str(self.project),
            CFG_CBMROOT_SETUP=str(self.setup),
            CFG_INPUT_DIR=str(self.input),
            CFG_OUTPUT_DIR=str(self.output),
            CFG_SETUP_TAG="fixture_setup",
            CFG_NEVENTS="1",
            SLURM_JOB_ID="local_test",
            SLURM_ARRAY_TASK_ID="1",
            H7_TRACE=str(self.trace),
        )
        for stage, key in [("tra", "CFG_TRA_CONFIG"), ("raw", "CFG_RAW_CONFIG"),
                           ("rec", "CFG_REC_CONFIG"), ("qa", "CFG_QA_CONFIG")]:
            config = self.root / (stage + ".yaml")
            config.write_text("fixture: true\n")
            self.env[key] = str(config)

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def run_stage(self, stage):
        return subprocess.run(
            ["bash", str(self.project / "sbash" / STAGES[stage][0])],
            env=self.env, text=True, capture_output=True, timeout=5,
        )

    def assert_stopped(self, result, status=None):
        if status is None:
            self.assertNotEqual(result.returncode, 0)
        else:
            self.assertEqual(result.returncode, status, result.stderr)
        self.assertFalse(self.trace.exists(), result.stdout + result.stderr)
        self.assertNotIn("Digitization completed:", result.stdout)

    def test_successful_stages_handle_paths_with_spaces(self):
        for stage, (_, folder, filename) in STAGES.items():
            with self.subTest(stage=stage):
                self.trace.unlink(missing_ok=True)
                result = self.run_stage(stage)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
                self.assertEqual(len(calls), 1)
                self.assertIn("FAKE_PROCESSING_OUTPUT", (self.output / folder / "1" / filename).read_text())
        self.assertEqual((self.output / "raw/1/1.par.root").read_text(), "parameter fixture")

    def test_failed_setup_stops_all_stages_and_preserves_status(self):
        self.setup.write_text(
            "export VMCWORKDIR=" + shlex.quote(str(self.vmc)) + "\nreturn 42\n"
        )
        for stage in STAGES:
            with self.subTest(stage=stage):
                result = self.run_stage(stage)
                self.assert_stopped(result, 42)
                self.assertIn("setup failed", result.stderr)

    def test_missing_setup_stops_all_stages(self):
        self.setup.unlink()
        for stage in STAGES:
            with self.subTest(stage=stage):
                self.assert_stopped(self.run_stage(stage))

    def test_missing_common_script_stops_all_stages(self):
        (self.project / "run_common.sh").unlink()
        for stage in STAGES:
            with self.subTest(stage=stage):
                result = self.run_stage(stage)
                self.assert_stopped(result)
                self.assertIn("Failed to load pipeline setup", result.stderr)

    def test_setup_without_environment_stops_all_stages(self):
        self.setup.write_text("return 0\n")
        for stage in STAGES:
            with self.subTest(stage=stage):
                result = self.run_stage(stage)
                self.assert_stopped(result)
                self.assertIn("VMCWORKDIR", result.stderr)

    def test_invalid_installation_layout_is_rejected(self):
        self.setup.write_text("export VMCWORKDIR=" + shlex.quote(str(self.root)) + "\n")
        for stage in STAGES:
            with self.subTest(stage=stage):
                self.assert_stopped(self.run_stage(stage))

    def test_trailing_slash_in_environment_is_supported(self):
        self.setup.write_text("export VMCWORKDIR=" + shlex.quote(str(self.vmc) + "/") + "\n")
        result = self.run_stage("transport")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.trace.exists())

    def test_directory_creation_failure_stops_all_stages(self):
        self.command("mkdir", "exit 31")
        for stage in STAGES:
            with self.subTest(stage=stage):
                self.assert_stopped(self.run_stage(stage), 31)

    def test_parameter_copy_failure_stops_digitization(self):
        self.command("cp", "exit 24")
        result = self.run_stage("digitization")
        self.assert_stopped(result, 24)

    def test_parameter_copy_preserves_paths_with_spaces(self):
        (self.output / "tra/1/1.par.root").write_text("new parameter contents")
        result = self.run_stage("digitization")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "raw/1/1.par.root").read_text(), "new parameter contents")

    def test_log_open_failure_stops_all_stages(self):
        for stage, (_, folder, filename) in STAGES.items():
            with self.subTest(stage=stage):
                log = self.output / folder / "1" / filename
                log.mkdir()
                result = self.run_stage(stage)
                self.assert_stopped(result)
                self.assertIn(str(log), result.stderr)
                log.rmdir()

    def test_processing_failure_preserves_status_and_reports_log(self):
        self.env["H7_BINARY_STATUS"] = "23"
        for stage, (_, folder, filename) in STAGES.items():
            with self.subTest(stage=stage):
                self.trace.unlink(missing_ok=True)
                result = self.run_stage(stage)
                self.assertEqual(result.returncode, 23)
                self.assertTrue(self.trace.exists())
                log = self.output / folder / "1" / filename
                self.assertIn(str(log), result.stderr)
                self.assertIn("Command failed with exit code 23", log.read_text())
                self.assertNotIn("Digitization completed:", result.stdout)


if __name__ == "__main__":
    unittest.main()
