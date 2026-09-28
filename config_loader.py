#!/usr/bin/env python3
"""Validate one run YAML and stage its CBMROOT YAML blocks for Slurm."""

import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("Configuration requires Python package PyYAML (python3 -m pip install PyYAML).")

FIELDS = {
    "task_range": "CFG_TASK_RANGE",
    "pipeline_test": "CFG_PIPELINE_TEST",
    "job_name": "CFG_JOB_NAME",
    "partition": "CFG_PARTITION",
    "mem_per_cpu": "CFG_MEM_PER_CPU",
    "time": "CFG_TIME",
    "log_dir": "CFG_LOG_DIR",
    "cbmroot_setup": "CFG_CBMROOT_SETUP",
    "input_dir": "CFG_INPUT_DIR",
    "output_dir": "CFG_OUTPUT_DIR",
    "setup_tag": "CFG_SETUP_TAG",
    "nevents": "CFG_NEVENTS",
}
PATHS = {"log_dir", "cbmroot_setup", "input_dir", "output_dir"}
STAGES = {"transport", "digitization", "reconstruction", "qa"}
BLOCKS = {
    "transport": ("tra.yaml", "CFG_TRA_CONFIG"),
    "digitization": ("raw.yaml", "CFG_RAW_CONFIG"),
    "reconstruction": ("rec.yaml", "CFG_REC_CONFIG"),
}


def fail(message):
    sys.exit(f"Invalid run configuration: {message}")


def validate(path):
    try:
        with path.open(encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as exc:
        fail(f"{path}: {exc}")
    if not isinstance(config, dict) or set(config) != {"run", *BLOCKS}:
        fail("expected run, transport, digitization, and reconstruction mappings")
    run = config["run"]
    if not isinstance(run, dict):
        fail("run must be a mapping")
    unknown = set(run) - set(FIELDS) - {"stages"}
    missing = set(FIELDS) | {"stages"}
    missing -= set(run)
    if unknown or missing:
        fail(f"run keys: unknown={sorted(map(str, unknown))}, missing={sorted(missing)}")

    stages = run["stages"]
    if not isinstance(stages, list) or not stages or any(
        not isinstance(stage, str) or stage not in STAGES for stage in stages
    ) or len(stages) != len(set(stages)):
        fail("run.stages must be a nonempty list without duplicates from: "
             "transport, digitization, reconstruction, qa")
    settings = {"CFG_STAGES": ",".join(stages)}
    for field, variable in FIELDS.items():
        value = run[field]
        if field == "pipeline_test":
            if not isinstance(value, bool):
                fail("run.pipeline_test must be true or false")
            value = str(value).lower()
        elif field == "nevents":
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                fail("run.nevents must be a positive integer")
            value = str(value)
        elif not isinstance(value, str) or not value:
            fail(f"run.{field} must be a nonempty string")
        if field in PATHS:
            value = value.replace("${USER}", os.environ.get("USER", ""))
            if "${" in value or "$(" in value or "`" in value:
                fail(f"run.{field} contains unsupported expansion")
            if not Path(value).is_absolute():
                fail(f"run.{field} must be an absolute path")
        if any(char in value for char in "\t\r\n"):
            fail(f"run.{field} cannot contain tabs or line breaks")
        settings[variable] = value
    if not re.fullmatch(
        r"[0-9]+(?:-[0-9]+)?(?:,[0-9]+(?:-[0-9]+)?)*",
        settings["CFG_TASK_RANGE"],
    ):
        fail("run.task_range must be a Slurm array range such as 1-20 or 1,3,7-10")
    if not Path(settings["CFG_CBMROOT_SETUP"]).is_file():
        fail(f"CBMROOT setup file does not exist: {settings['CFG_CBMROOT_SETUP']}")
    for section in BLOCKS:
        if not isinstance(config[section], dict) or not config[section]:
            fail(f"{section} must be a nonempty YAML mapping")
    return config, settings


def main():
    if len(sys.argv) != 2:
        fail("expected one YAML path")
    path = Path(sys.argv[1]).expanduser().resolve()
    config, settings = validate(path)

    log_dir = Path(settings["CFG_LOG_DIR"])
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        bundle = Path(tempfile.mkdtemp(prefix="config.", dir=log_dir))
        try:
            shutil.copyfile(path, bundle / "run.yaml")
            for section, (name, variable) in BLOCKS.items():
                target = bundle / name
                with target.open("w", encoding="utf-8") as stream:
                    yaml.safe_dump(config[section], stream, sort_keys=False)
                settings[variable] = str(target)
        except (OSError, yaml.YAMLError):
            shutil.rmtree(bundle)
            raise
    except (OSError, yaml.YAMLError) as exc:
        fail(f"could not stage configuration: {exc}")

    settings["CFG_RUN_CONFIG"] = str(bundle / "run.yaml")
    for key, value in settings.items():
        print(f"{key}\t{value}")


if __name__ == "__main__":
    main()
