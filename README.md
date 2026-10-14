# CBMROOT Slurm Pipeline

Configure, run, and check CBMROOT transport, digitization, reconstruction, and quality assurance (QA) using Bash scripts. The main entry point, `run_jobs.sh`, supports Slurm submission and concurrent local execution.

> Real QA requires a project-local `run_qa.C` macro that is not included in this repository. Its aggregate output also differs from the per-task layout expected by QA checking and merging helpers. Read the QA section before selecting that stage.

## Requirements

- Linux and Bash; **Bash 5.1 or newer for local mode**, which uses `wait -n -p`.
- Python 3 and PyYAML on the host running the launcher.
- `sbatch` and `squeue` for Slurm execution.
- An installed CBMROOT environment for real processing, with an existing absolute `VMCWORKDIR` ending in `/share/cbmroot` (a trailing slash is accepted).
- Installed `cbmsim_transport`, `cbmsim_digitization`, and `cbmreco_offline` executables under the installation's `bin/` directory.
- ROOT's `root` command for reconstruction's prerequisite check and QA; `hadd` for the default QA merger.
- Standard Linux utilities, including `xargs`, `gzip`, and `grep` for checking results. SSH and `rsync` are needed for remote execution/synchronization.
- Readable input data and writable output/log storage. Compute nodes must be able to access the project, CBMROOT setup, data, and configuration snapshots.

## Quick start

```bash
git clone https://github.com/googol23/cbmroot_sbatch.git
cd cbmroot_sbatch
python3 -m pip install PyYAML
chmod +x *.sh *.sbash
cp default_config.yaml my_run.yaml
```

Edit `my_run.yaml` for your installation and storage, then start with two tasks and the three processing stages:

```bash
./run_jobs.sh my_run.yaml -t -d -r -j 1-2
```

This submits Slurm jobs; it does not wait for completion. Monitor the printed job IDs and check processing logs after the jobs finish.

## Command-line interface

```text
./run_jobs.sh [run_config.yaml] [OPTIONS]
```

| Option | Meaning |
| --- | --- |
| `-t`, `--transport` | Select transport. |
| `-d`, `--digitization` | Select digitization. |
| `-r`, `--reconstruction` | Select reconstruction. |
| `--qa` | Select full-chain QA; requires `run_qa.C`. |
| `--qa-mode MODE` | Select `full`, `per_step`, or `both` QA behavior. |
| `-j RANGE`, `--jobs RANGE` | Override `run.task_range`. |
| `--test` | Replace selected stages with `success.sbash`. |
| `--local` | Execute locally instead of submitting to Slurm. |
| `-h`, `--help` | Display usage. |

With an explicit YAML and no stage flags, stages come from `run.stages`. Any stage flags replace that list. Execution order is always transport → digitization → reconstruction → QA, regardless of flag or YAML order.

Without an explicit YAML, other settings come from `default_config.yaml`, but stage selection comes from CLI flags. A bare `./run_jobs.sh` selects no stages.

Task selections accept `1`, `1-20`, or `1,3,7-10`. Use ascending ranges and decimal IDs without leading zeros. Array strides (`1-20:2`) and concurrency suffixes (`1-20%4`) are not accepted. Selecting a later stage does not add earlier stages; its inputs must already exist.

## Configuration

Each YAML must contain exactly five top-level, nonempty mappings: `run`, `transport`, `digitization`, `reconstruction`, and `qa`. All four stage mappings remain required for partial runs and test mode.

Example `run` section, to accompany the stage mappings copied from `default_config.yaml`:

```yaml
run:
  stages: [transport, digitization, reconstruction]
  task_range: "1-2"
  pipeline_test: false
  job_name: cbmsim
  partition: long
  mem_per_cpu: 16G
  time: "01:00:00"
  cbmroot_setup: /path/to/cbmroot/install/bin/CbmRootConfig.sh
  input_dir: /path/to/generator/root
  output_dir: /path/to/output/my_run
  log_dir: /path/to/output/my_run/log
  setup_tag: sis100_electron
  nevents: 1
```

| Required key under `run` | Purpose / requirements |
| --- | --- |
| `stages` | Nonempty list without duplicates: `transport`, `digitization`, `reconstruction`, `qa`. |
| `task_range` | String using the task syntax above; quote numeric-only values. |
| `pipeline_test` | YAML boolean; CLI `--test` forces `true`. |

| `job_name` | Slurm job-name prefix; stage suffixes are added. |
| `partition` | Slurm partition. |
| `mem_per_cpu` | Slurm memory per CPU, as a string such as `16G`. |
| `time` | Slurm time-limit string. |
| `cbmroot_setup` | Absolute setup-script path; must exist as a file outside test mode. |
| `input_dir` | Absolute generator input directory. |
| `output_dir` | Absolute processing output directory. |
| `log_dir` | Absolute scheduler log and configuration snapshot directory. |
| `setup_tag` | CBMROOT detector setup tag. |
| `nevents` | Positive integer; passed as `-n` to transport/digitization and `--ntimeslices` to reconstruction. |

Unknown or missing `run` keys are rejected. Except for `stages`, `pipeline_test`, and `nevents`, values must be nonempty strings. Paths support literal `${USER}` substitution, not arbitrary shell expansion. The loader validates stage mappings structurally; CBMROOT validates their detailed settings.

### `qa`

```yaml
qa:
  mode: full
```

`qa.mode` is required and accepts `full`, `per_step`, or `both`. The complete `qa` mapping is staged as `qa.yaml` and exported to jobs as `CFG_QA_CONFIG`, matching `CFG_TRA_CONFIG`, `CFG_RAW_CONFIG`, and `CFG_REC_CONFIG`. Additional QA binary settings can therefore be added to this block later without changing the pipeline's configuration structure.

Supplied examples contain installation-specific paths:

- `default_config.yaml`: tasks `1-100`, 999 events, all four stages.
- `test_config.yaml`: tasks `1-2`, one event, cluster paths.
- `test_config_local.yaml`: tasks `1-2`, one event, local installation paths; MVD is deactivated in digitization.

Both test configurations set `pipeline_test: false`; they run real processing unless `--test` is supplied. Adapt paths and stage selections before use.

The launcher uses embedded stage mappings, not the separate `traConfig.yaml`, `rawConfig.yaml`, or `recConfig.yaml` references. `innactive_channel_config.yaml` is an additional example and is not automatically loaded.

### Snapshots and overlapping runs

Each launch creates `log_dir/config.*` containing a copy named `run.yaml` and extracted `tra.yaml`, `raw.yaml`, and `rec.yaml`. Jobs receive the resolved settings and file paths through exported environment variables. Keep snapshots and scripts accessible until jobs finish.

The copied `run.yaml` retains the original YAML; CLI overrides are exported rather than written back into that file. Use distinct output and log directories for overlapping runs: processing commands use overwrite options, and QA removes its previous aggregate output before running.

## Slurm execution

Transport, digitization, and reconstruction are arrays using the same task selection. When adjacent stages are selected, `aftercorr` makes each digitization task wait for its corresponding transport task and each reconstruction task wait for its corresponding digitization task.

No direct transport-to-reconstruction dependency is added when digitization is omitted. In `full` or `both` mode, aggregate QA uses `afterok` and starts only after every selected simulation array finishes successfully. In `per_step` or `both` mode, each selected simulation array spawns a corresponding QA array with `aftercorr`; these QA arrays do not gate downstream simulation stages.

| Stage | Scheduler stdout pattern under `log_dir` |
| --- | --- |
| Transport | `%a_%A.tra.log` |
| Digitization | `%a_%A.dig.log` |
| Reconstruction | `%a_%A.rec.log` |
| Per-step transport QA | `%a_%A.tra.qa.log` |
| Per-step digitization QA | `%a_%A.dig.qa.log` |
| Per-step reconstruction QA | `%a_%A.rec.qa.log` |
| Full-chain QA | `%j.qa.log` |

`%a` is the array task ID, `%A` the array job ID, and `%j` the job ID. CBMROOT output is captured separately in the stage logs under `output_dir`.

The final queue summary covers the user's entire Slurm queue. Successful submission does not establish successful processing.

## Local execution

```bash
LOCAL_MAX_JOBS=2 ./run_jobs.sh my_run.yaml -t -d -r -j 1-2 --local
```

Stages run sequentially within each task; different task pipelines run concurrently. `LOCAL_MAX_JOBS` is a positive integer, defaulting to `4`. It limits pipelines, not application threads. Slurm memory, partition, and time settings do not enforce local resource limits.

The launcher supplies the job/task environment variables expected by the scripts, waits for local pipelines, and returns `0` when all succeed or `1` when any fails. Real local execution still requires CBMROOT and input data.

### Pipeline smoke test

```bash
./run_jobs.sh my_run.yaml -t -d -r -j 1-2 --local --test
```

`--test` or `pipeline_test: true` replaces selected stages with `success.sbash`, which prints job/task information, sleeps one second, and reports completion. It does not load CBMROOT, process data, produce ROOT files, or create normal stage logs. The configuration must still be valid and `log_dir` writable. Test mode without `--local` still requires Slurm.

## Input and output layout

Task `ID` reads `input_dir/dcmqgsm_ID.root`.

| Stage | Files relative to `output_dir` |
| --- | --- |
| Transport | `tra/ID/ID.tra.root`, `tra/ID/ID.par.root`, `tra/ID/transport.log` |
| Digitization | `raw/ID/ID.digi.root`, `raw/ID/ID.par.root`, `raw/ID/digitization.log` |
| Reconstruction | `rec/ID/ID.reco.root`, `rec/ID/reconstruction.log` |
| Per-step QA | `qa/ID/ID.tra.qa.root`, `ID.digi.qa.root`, `ID.reco.qa.root` and matching logs |
| Aggregate QA | `qa/qa.root`, `qa/qa.log` |

Digitization copies transport parameters into its own task directory. Reconstruction consumes transport output, digitization output, and digitization parameters. Full-chain QA consumes the completed task range. Per-step QA writes beneath each task's `qa/ID` directory.

Per-step launchers are `run_tra_qa.sbash`, `run_raw_qa.sbash`, and `run_rec_qa.sbash`. They expect project-local macros named `run_tra_qa.C`, `run_raw_qa.C`, and `run_rec_qa.C`, each with this interface:

```cpp
void run_STAGE_qa(TString outputDir, Int_t taskId, TString setup,
                  Int_t nEvents, TString qaOutput);
```

This gives each macro the pipeline output root and task ID so it can locate all required stage inputs, while requiring its result to be written under `QA_OUT_DIR`.

## Checking results

Use the unified checker for current processing output:

```bash
./check_jobs.sh --stage tra,raw,reco --detailed --no-color /path/to/output/my_run "1-2"
```

Checker stage names are `tra`, `raw`, `reco`, and `qa`, or `all` (default). `-j N` controls parallel checks; default `auto` uses available CPUs capped at 16. Put options before the output root and range.

For processing stages, the checker accepts plain and gzip-compressed logs, preferring `.gz` if both exist. It recognizes `Macro finished successfully.` or the appropriate executable-specific message:

| Stage | Additional success message |
| --- | --- |
| Transport | `CBM Transport: Program completed successfully; exiting.` |
| Digitization | `CBM Digitization: Program completed successfully; exiting.` |
| Reconstruction | `Run: Execution successful` |

Exit codes: `0` for all selected logs passing, `1` for failed/missing logs, and `2` for invalid arguments or checker errors. This checks log messages, not ROOT integrity or scheduler state.

Older `check_tra.sh`, `check_raw.sh`, and `check_rec.sh` support `--detailed`, but require `.log.gz` files and only recognize `Macro finished successfully.` The launcher writes plain logs, so these helpers can report failures for valid current output.

`check_qa.sh` and the unified checker's QA stage expect `qa/ID/ID.qa.log`, not aggregate `qa/qa.log`. Select processing stages explicitly when checking the current launcher's output.

## QA behavior and requirements

`run_qa.sbash` expects `run_qa.C` beside the project scripts and invokes:

```text
run_qa.C("output_dir", "task_range", "setup_tag", -1)
```

Supply a compatible macro that creates a nonempty `output_dir/qa/qa.root`; console output goes to `output_dir/qa/qa.log`.

Current scheduling has these limitations:

- Slurm QA is one non-array job with **no dependency on reconstruction**. Launch QA separately after processing completes.
- Local mode invokes aggregate QA within each selected task pipeline, passing the full range every time. Concurrent pipelines can overwrite the same QA files. For aggregate QA, use a separate invocation with one local task after all inputs exist.
- QA checking and merging helpers target per-task files and do not directly consume aggregate output.

Pipeline test mode substitutes the smoke-test script and does not validate real QA.

### Merging existing per-task QA files

`merge_qa.sh` expects `qa/ID/ID.qa.log` and `qa/ID/ID.qa.root`. It selects only files with the success marker and a nonempty ROOT file.

```bash
./merge_qa.sh --list-only --file-list files.txt /path/to/per-task/qa "1-20"
```

Default merging uses `hadd` with four jobs and writes `<qa_dir>/merged.root`. Options: `-o/--output`, `-j/--jobs`, `-m/--merger`, `-l/--file-list`, and `--list-only`. Custom executables receive `file_list output.root`; ROOT macros receive the same two arguments.

`merge_qa.C` merges only four selected momentum histograms under `CbmCaOutputQa/prim`, as defined in `selectedObjects`; it is not a full-file merger. Failed tasks are excluded, and merging can return success despite exclusions. Inspect the summary and output contents.

## Remote execution and synchronization

On hostnames beginning with `lxi`, nonlocal launches prompt for remote execution on `vae25-virgo4.hpc.gsi.de`, followed by optional synchronization. `--local` bypasses this routing. The check is hostname-based, not a check for Slurm availability.

The remote project path in `run_jobs.sh` is hardcoded to `/lustre/cbm/users/dramirez/slurm_scripts_v3/`; adapt it and the SSH host to your environment.

Arguments are preserved, and execution starts in the remote project directory. Project-local configurations map to the same relative remote location. Relative paths resolve from the caller's working directory, with an existing parent inside the project. External configurations require an absolute path accessible remotely. Argument forwarding alone does not copy files.

`sync.sh [DEST]` uses SSH/rsync to `lustre.hpc.gsi.de`, copying top-level `.sbash`, `.sh`, `.py`, `.yaml`, `.yml`, and `.C` files from the current working directory. Run it from the repository root. Its filters exclude nested directories, tests, and the README; copy nested configurations separately. The launcher's optional synchronization also assumes `sync.sh` is in the current working directory.

## Verification and troubleshooting

Run the regression suite without a real cluster or CBMROOT installation:

```bash
python3 -m unittest discover -s tests -v
```

Tests cover smoke-test behavior, remote argument forwarding, and processing-stage failure handling using controlled substitutes for external tools. During this README review of commit `15bdcd919d8bdb514fafeb330991dcf4ff242171`, all **43 tests passed**, and Bash syntax checks passed for all **15 shell scripts**. Real Slurm, CBMROOT, ROOT QA, and remote-cluster processing were not rerun.

For failures, inspect scheduler stdout and stage logs. Check setup-script access, executable paths, generator filenames, upstream input files, and compute-node access to snapshots. A smoke-test success validates orchestration only.

`run_test.sh` is a legacy hardcoded transport experiment with digitization/reconstruction commands commented out. Use `run_jobs.sh --test` for the maintained pipeline smoke test.

## License

No license file is included in the reviewed repository.
