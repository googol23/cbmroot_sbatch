"""Verify QA jobs use the intended Slurm dependency graph."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


PROJECT = Path(__file__).resolve().parents[1]


class QaSchedulingTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="cbm-qa-scheduling-")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name)
        self.project = self.root / "project"
        shutil.copytree(PROJECT, self.project, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.trace = self.root / "sbatch.jsonl"
        self.setup = self.root / "setup.sh"
        self.setup.write_text(":\n")
        self.config = yaml.safe_load((PROJECT / "default_config.yaml").read_text())
        self.config["run"].update(
            stages=["transport", "digitization", "reconstruction", "qa"],
            task_range="1-2",
            pipeline_test=True,
            cbmroot_setup=str(self.setup),
            input_dir=str(self.root / "input"),
            output_dir=str(self.root / "output"),
            log_dir=str(self.root / "logs"),
        )
        self.config_path = self.root / "run.yaml"
        self.config_path.write_text(yaml.safe_dump(self.config))
        self.command(
            "sbatch",
            "#!" + sys.executable + "\n"
            "import json, os, sys\n"
            "path = os.environ['QA_SBATCH_TRACE']\n"
            "with open(path, 'a') as stream: stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "print(sum(1 for _ in open(path)))\n",
        )
        self.command("squeue", "#!/bin/sh\nexit 0\n")
        self.command("hostname", "#!/bin/sh\nprintf 'submit-node\\n'\n")
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"], QA_SBATCH_TRACE=str(self.trace))

    def command(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_launcher(self, mode):
        result = subprocess.run(
            ["bash", str(self.project / "run_jobs.sh"), str(self.config_path), "--qa-mode", mode],
            env=self.env, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in self.trace.read_text().splitlines()]

    def test_both_mode_spawns_non_blocking_step_qa_and_deferred_full_qa(self):
        calls = self.run_launcher("both")
        self.assertEqual(len(calls), 7)
        scripts = [Path(call[-1]).name for call in calls]
        self.assertEqual(scripts, [
            "success.sbash", "success.sbash", "success.sbash", "success.sbash",
            "success.sbash", "success.sbash", "success.sbash",
        ])
        dependencies = [[arg for arg in call if arg.startswith("--dependency=")] for call in calls]
        self.assertEqual(dependencies[0], [])
        self.assertEqual(dependencies[1], ["--dependency=aftercorr:1"])
        self.assertEqual(dependencies[2], ["--dependency=aftercorr:1"])
        self.assertEqual(dependencies[3], ["--dependency=aftercorr:3"])
        self.assertEqual(dependencies[4], ["--dependency=aftercorr:3"])
        self.assertEqual(dependencies[5], ["--dependency=aftercorr:5"])
        self.assertEqual(dependencies[6], ["--dependency=afterok:1:3:5"])

    def test_per_step_mode_does_not_submit_full_qa(self):
        self.config["qa"]["mode"] = "per_step"
        self.config_path.write_text(yaml.safe_dump(self.config))
        calls = self.run_launcher("per_step")
        self.assertEqual(len(calls), 6)
        self.assertFalse(any(
            arg.startswith("--dependency=afterok:")
            for call in calls for arg in call
        ))


if __name__ == "__main__":
    unittest.main()
