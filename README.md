# CBMROOT Slurm Pipeline

This repository contains Bash scripts for running and monitoring CBMROOT simulation workflows on a Slurm-managed computing cluster.

The workflow is organized into the usual processing stages:

1. Transport simulation
2. Digitization
3. Reconstruction
4. Quality assurance (QA)

Each stage can be submitted as a Slurm array job. Output from every array task is stored in a task-specific directory, allowing many input files to be processed independently.

## Requirements

- Linux with Bash
- A Slurm workload manager (`sbatch`, `squeue`)
- A working CBMROOT environment
- Access to the required input data and cluster storage
- ROOT for QA macros that use it

The scripts contain installation paths, input paths, output paths, setup tags, resource limits, and configuration-file locations that must be adapted to the local environment.

## Basic usage

Make the scripts executable:

```bash
chmod +x *.sh *.sbash
```

Submit selected processing stages for a Slurm array:

```bash
./submit.sh --transport --digitization --reconstruction --jobs 1-20
```

Stage names and submission-script names may differ slightly depending on the current repository version. Run the relevant script with `--help`, or inspect its option definitions, before submission.

Task selections generally support Slurm array expressions such as:

```text
1
1-20
1,3,7-10
```

## Checking results

The repository includes helper scripts that inspect stage log files and look for the expected successful-completion message.

Example:

```bash
./check_tra.sh /path/to/output/tra "1-20"
```

Where supported, use `--detailed` to print individual successful and failed tasks:

```bash
./check_rec.sh --detailed /path/to/output/reco "1,3,7-10"
```

Check scripts return exit code `0` when all requested tasks pass and `1` when a log is missing or a task did not finish successfully. This makes them suitable for use in other scripts.

## Output layout

A typical output tree is:

```text
output/
├── tra/<task-id>/
├── raw/<task-id>/
├── reco/<task-id>/
└── qa/<task-id>/
```

Each directory contains the data, parameter, and log files produced for that task and processing stage.

## Configuration

Before running the pipeline, review at least:

- CBMROOT environment setup path
- Input and output directories
- YAML configuration files
- Detector setup tag
- Number of events
- Slurm partition, memory, and time limits
- Executable and macro paths

Some QA paths may be placeholders while the corresponding macros are under development.

## Notes

- Submit scripts through Slurm so that variables such as `SLURM_JOB_ID` and `SLURM_ARRAY_TASK_ID` are available.
- Later stages expect output and parameter files from earlier stages.
- Verify the configured paths before launching large arrays.
- Test with a small task range before a full production run.

## License

No license is specified. Add one if the repository is intended for redistribution or external reuse.
