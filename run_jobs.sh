#!/usr/bin/env bash
set -euo pipefail

USER="${USER:-$(id -un)}"
export USER

usage() {
    cat <<'EOF'
Usage: ./run_jobs.sh [run_config.yaml] [OPTIONS]
  -t, --transport       Submit/run transport
  -d, --digitization    Submit/run digitization
  -r, --reconstruction  Submit/run reconstruction
      --qa              Select full-chain QA
      --qa-mode MODE    QA mode: full, per_step, or both
  -j, --jobs RANGE      Slurm/local task range
      --test            Run the success test script instead
      --local           Run jobs locally instead of submitting to Slurm
      --debug           Preserve the remote run snapshot after completion
  -h, --help            Show this help

Stage flags replace the YAML stage list when any are supplied.

Local mode:
  Each task is run as an independent pipeline in the background.
  The maximum number of concurrent task pipelines is controlled by
  LOCAL_MAX_JOBS (default: 4).

Examples:
  ./run_jobs.sh config.yaml -t -d -r
  ./run_jobs.sh config.yaml -t -d -r -j 1-5
  ./run_jobs.sh config.yaml -t -d -r -j 1-5 --local
  30	  LOCAL_MAX_JOBS=2 ./run_jobs.sh config.yaml -t -d -r -j 1-10 --local
EOF
}

remote_exec_warning() {
    cat <<'EOF'
You are currently on executing the script in an enviorement that do not support SLURM jobs submission.

EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Argument parsing consumes the positional parameters needed for remote execution.
declare -a original_args=("$@")
config_file=""
config_arg_index=""
declare -a selected_stages=()
jobs_override=""
qa_mode_override=""
test_override=false
local_mode=false
debug_mode=false

while (( $# )); do
    case "$1" in
        -t|--transport)
            selected_stages+=(transport)
            shift
            ;;
        -d|--digitization)
            selected_stages+=(digitization)
            shift
            ;;
        -r|--reconstruction)
            selected_stages+=(reconstruction)
            shift
            ;;
        --qa)
            selected_stages+=(qa)
            shift
            ;;
        --qa-mode)
            if (( $# < 2 )); then
                echo "$1 requires one of: full, per_step, both" >&2
                exit 2
            fi
            qa_mode_override="$2"
            shift 2
            ;;
        --test)
            test_override=true
            shift
            ;;
        --local)
            local_mode=true
            shift
            ;;
        --debug)
            debug_mode=true
            shift
            ;;
        -j|--jobs)
            if (( $# < 2 )); then
                echo "$1 requires a range" >&2
                exit 2
            fi
            jobs_override="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$config_file" ]]; then
                echo "Only one configuration file is allowed" >&2
                exit 2
            fi
            config_file="$1"
            config_arg_index=$(( ${#original_args[@]} - $# ))
            shift
            ;;
    esac
done

# Configuration files live under config/. Preserve explicit paths, but allow
# the convenient basename form used before the project reorganization.
if [[ -n "$config_file" && "$config_file" != /* && ! -e "$config_file" &&
      -f "${SCRIPT_DIR}/config/${config_file}" ]]; then
    config_file="${SCRIPT_DIR}/config/${config_file}"
fi

# ---------------------------------------------------------------------------
# Host determination
# ---------------------------------------------------------------------------
if ! "$local_mode"; then
  if [[ "$(hostname)" == "lxi"* ]]; then
    remote_exec_warning
    SYNC_ROOT=/lustre/cbm/users/${USER}/slurm_scripts_v3
    snapshot_id="${CBM_SNAPSHOT_ID:-}"
    if [[ -z "$snapshot_id" ]]; then
      printf -v snapshot_id '%(%Y%m%dT%H%M%S)T-%s' -1 "$$"
    elif [[ ! "$snapshot_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "Invalid CBM_SNAPSHOT_ID: $snapshot_id" >&2
      exit 2
    fi
    SYNC_PATH="${SYNC_ROOT}/run-${snapshot_id}"
    read -p "Current mode is set to remote execution, confirm you want to execute the command in a virgo node: [y/n]" -n 1 -r
    echo    # (optional) move to a new line
  
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      remote_args=("${original_args[@]}")
      if [[ -n "$config_file" ]]; then
        # Project configs move with the project; other absolute paths refer
        # to shared storage or a config already present on the submission host.
        if [[ "$config_file" != /* || "$config_file" == "$SCRIPT_DIR/"* ]]; then
          config_parent="$(dirname -- "$config_file")"
          if ! config_parent="$(cd -- "$config_parent" && pwd -P)"; then
            echo "Cannot resolve configuration directory: $config_file" >&2
            exit 2
          fi
          config_path="${config_parent}/${config_file##*/}"
          if [[ "$config_path" == "$SCRIPT_DIR/"* ]]; then
            remote_args[config_arg_index]="${SYNC_PATH%/}/${config_path#"$SCRIPT_DIR/"}"
          elif [[ "$config_file" != /* ]]; then
            echo "Configuration is outside the project; use an absolute path on the submission host: $config_file" >&2
            exit 2
          fi
        fi
      fi

      echo "Synchronization of remote folder is adviced."
      read -p "Please confirm you want to synchronize the current script state to the remote folde: ${SYNC_PATH}? [y/n]" -n 1 -r
      echo    # (optional) move to a new line
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        "${SCRIPT_DIR}/utils/sync.sh" "${SYNC_PATH}"
      fi

      # SSH passes a command string to the login shell. POSIX single-quote
      # escaping preserves argument boundaries without requiring Bash there.
      quote_remote_arg() {
        local escaped="${1//\'/\'\\\'\'}"
        printf "'%s'" "$escaped"
      }

      remote_command="cd $(quote_remote_arg "$SYNC_PATH")"
      remote_command+=" && export CBM_RUN_SNAPSHOT=true"
      remote_command+=" CBM_RUN_SNAPSHOT_ROOT=$(quote_remote_arg "$SYNC_ROOT")"
      remote_command+=" && exec bash ./run_jobs.sh"
      for arg in "${remote_args[@]}"; do
        remote_command+=" $(quote_remote_arg "$arg")"
      done

      echo "Remote execution by:"
      printf 'ssh %s %s\n' "${USER}@vae25-virgo4.hpc.gsi.de" "$remote_command"
      exec ssh "${USER}@vae25-virgo4.hpc.gsi.de" "$remote_command"
    else
      exit 1
    fi
  fi
fi
echo "Command executed at: "
hostname

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
explicit_config=false

if [[ -n "$config_file" ]]; then
    explicit_config=true
else
    config_file="${SCRIPT_DIR}/config/default_config.yaml"
fi

CBM_RUN_DIR="$SCRIPT_DIR"
export CBM_RUN_DIR

loader_args=("$config_file")

if "$test_override"; then
    loader_args+=(--test)
fi

settings="$(
    python3 "${SCRIPT_DIR}/utils/config_loader.py" "${loader_args[@]}"
)" || exit 1

while IFS=$'\t' read -r key value; do
    printf -v "$key" '%s' "$value"
    export "$key"
done <<< "$settings"

# ---------------------------------------------------------------------------
# Select pipeline stages
# ---------------------------------------------------------------------------
RUN_TRA=false
RUN_DIG=false
RUN_REC=false
RUN_QA=false

if [[ "$explicit_config" == true && ${#selected_stages[@]} -eq 0 ]]; then
    IFS=',' read -ra selected_stages <<< "$CFG_STAGES"
fi

for stage in "${selected_stages[@]}"; do
    case "$stage" in
        transport)      RUN_TRA=true ;;
        digitization)   RUN_DIG=true ;;
        reconstruction) RUN_REC=true ;;
        qa)             RUN_QA=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Task range
# ---------------------------------------------------------------------------

TASK_RANGE="${jobs_override:-$CFG_TASK_RANGE}"
export TASK_RANGE

if [[ ! "$TASK_RANGE" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
    echo "Invalid task range: $TASK_RANGE" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Test mode
# ---------------------------------------------------------------------------
# The loader resolves YAML settings and the CLI test override.
PIPELINE_TEST="$CFG_PIPELINE_TEST"
QA_MODE="${qa_mode_override:-$CFG_QA_MODE}"
if [[ "$QA_MODE" != full && "$QA_MODE" != per_step && "$QA_MODE" != both ]]; then
    echo "Invalid QA mode: $QA_MODE (expected full, per_step, or both)" >&2
    exit 2
fi
RUN_STEP_QA=false
if [[ "$QA_MODE" == per_step || "$QA_MODE" == both ]]; then
    RUN_STEP_QA=true
fi
if [[ "$QA_MODE" == per_step ]]; then
    RUN_QA=false
fi

# ---------------------------------------------------------------------------
# Common configuration
# ---------------------------------------------------------------------------
job_name="$CFG_JOB_NAME"
partition="$CFG_PARTITION"
ram="$CFG_MEM_PER_CPU"
log_dir="$CFG_LOG_DIR"

if "$PIPELINE_TEST"; then
    tra_exe=success.sbash
    raw_exe=success.sbash
    rec_exe=success.sbash
    qa_exe=success.sbash
    tra_qa_exe=success.sbash
    raw_qa_exe=success.sbash
    rec_qa_exe=success.sbash
else
    tra_exe=run_tra.sbash
    raw_exe=run_raw.sbash
    rec_exe=run_rec.sbash
    qa_exe=run_qa.sbash
    tra_qa_exe=run_tra_qa.sbash
    raw_qa_exe=run_raw_qa.sbash
    rec_qa_exe=run_rec_qa.sbash
fi

# ===========================================================================
# Local execution
# ===========================================================================
if "$local_mode"; then

    # Maximum number of independent task pipelines running concurrently.
    LOCAL_MAX_JOBS="${LOCAL_MAX_JOBS:-4}"

    if [[ ! "$LOCAL_MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "LOCAL_MAX_JOBS must be a positive integer" >&2
        exit 2
    fi

    # Convert a Slurm-style task range:
    #
    #   1-4       -> 1 2 3 4
    #   1,3,7-9   -> 1 3 7 8 9
    #
    expand_task_range() {
        local part start end i
        local -a parts

        IFS=',' read -ra parts <<< "$TASK_RANGE"

        for part in "${parts[@]}"; do
            if [[ "$part" == *-* ]]; then
                IFS='-' read -r start end <<< "$part"

                if (( start > end )); then
                    echo "Invalid descending task range: $part" >&2
                    return 1
                fi

                for ((i=start; i<=end; i++)); do
                    printf '%s\n' "$i"
                done
            else
                printf '%s\n' "$part"
            fi
        done
    }

    # Run one complete task pipeline.
    #
    # This intentionally runs the selected stages sequentially for a given
    # task. Therefore:
    #
    #   transport -> digitization -> reconstruction -> QA
    #
    # behaves similarly to Slurm's aftercorr dependencies.
    #
    # Different TASK_IDs are run concurrently.
    run_local_task() {
        local task_id="$1"

        (
            # Emulate the Slurm variables expected by run_common.sh.
            export SLURM_JOB_ID="local_${BASHPID}"
            export SLURM_ARRAY_TASK_ID="$task_id"

            echo "============================================================"
            echo "Local task ${task_id} started (PID ${BASHPID})"
            echo "============================================================"

            if "$RUN_TRA"; then
                echo "[local:${task_id}] Starting Transport"
                "${SCRIPT_DIR}/sbash/${tra_exe}"
                echo "[local:${task_id}] Transport completed"
                if "$RUN_STEP_QA"; then
                    echo "[local:${task_id}] Starting Transport QA"
                    "${SCRIPT_DIR}/sbash/${tra_qa_exe}" ||
                        echo "[local:${task_id}] WARNING: Transport QA failed" >&2
                fi
            fi

            if "$RUN_DIG"; then
                echo "[local:${task_id}] Starting Digitization"
                "${SCRIPT_DIR}/sbash/${raw_exe}"
                echo "[local:${task_id}] Digitization completed"
                if "$RUN_STEP_QA"; then
                    echo "[local:${task_id}] Starting Digitization QA"
                    "${SCRIPT_DIR}/sbash/${raw_qa_exe}" ||
                        echo "[local:${task_id}] WARNING: Digitization QA failed" >&2
                fi
            fi

            if "$RUN_REC"; then
                echo "[local:${task_id}] Starting Reconstruction"
                "${SCRIPT_DIR}/sbash/${rec_exe}"
                echo "[local:${task_id}] Reconstruction completed"
                if "$RUN_STEP_QA"; then
                    echo "[local:${task_id}] Starting Reconstruction QA"
                    "${SCRIPT_DIR}/sbash/${rec_qa_exe}" ||
                        echo "[local:${task_id}] WARNING: Reconstruction QA failed" >&2
                fi
            fi

            echo "============================================================"
            echo "Local task ${task_id} completed"
            echo "============================================================"
        )
    }

    mapfile -t local_tasks < <(expand_task_range)

    echo "================ Local Execution ================"
    echo "Task range:          $TASK_RANGE"
    echo "Number of tasks:     ${#local_tasks[@]}"
    echo "Maximum concurrency: $LOCAL_MAX_JOBS"
    echo "Transport:           $RUN_TRA"
    echo "Digitization:        $RUN_DIG"
    echo "Reconstruction:      $RUN_REC"
    echo "Full-chain QA:       $RUN_QA"
    echo "Per-step QA:         $RUN_STEP_QA"
    echo "================================================="

    declare -A local_pids=()
    local_failures=0

    # Wait for one background task and propagate its status into our
    # aggregate failure count.
    wait_for_one() {
        local finished_pid
        local status

        # Bash >= 5.1 supports wait -n -p.
        if wait -n -p finished_pid; then
            status=0
        else
            status=$?
        fi

        if (( status != 0 )); then
            echo "Local task process ${finished_pid:-unknown} failed with exit code ${status}" >&2
            ((local_failures += 1))
        fi

        if [[ -n "${finished_pid:-}" ]]; then
            unset 'local_pids[$finished_pid]'
        fi
    }

    for task_id in "${local_tasks[@]}"; do

        # Throttle the number of concurrent task pipelines.
        while (( ${#local_pids[@]} >= LOCAL_MAX_JOBS )); do
            wait_for_one
        done

        run_local_task "$task_id" &

        pid=$!
        local_pids["$pid"]="$task_id"

        echo "Local task ${task_id} launched as PID ${pid}"
    done

    # Wait for all remaining pipelines.
    while (( ${#local_pids[@]} > 0 )); do
        wait_for_one
    done

    if "$RUN_QA" && (( local_failures == 0 )); then
        echo "Starting full-chain QA after all local simulation tasks"
        if (
            export SLURM_JOB_ID="local_qa_${BASHPID}"
            unset SLURM_ARRAY_TASK_ID
            "${SCRIPT_DIR}/sbash/${qa_exe}"
        ); then
            echo "Full-chain QA completed"
        else
            qa_status=$?
            echo "Full-chain QA failed with exit code ${qa_status}" >&2
            ((local_failures += 1))
        fi
    fi

    echo
    echo "================ Local Summary =================="

    if (( local_failures == 0 )); then
        echo "All local tasks completed successfully."
        echo "================================================="
        exit 0
    else
        echo "${local_failures} local task(s) failed."
        echo "================================================="
        exit 1
    fi
fi

# ===========================================================================
# Slurm execution
# ===========================================================================

build_clpars() {
    local -n result=$1
    local stage=$2

    result=(
        "--partition=$partition"
        "--array=$TASK_RANGE"
        "--export=ALL"
        "--kill-on-invalid-dep=yes"
        "--job-name=${job_name}_${stage}"
        "--mem-per-cpu=$ram"
        "--time=$CFG_TIME"
        "--output=${log_dir}/%a_%A.${stage}.log"
    )
}

build_clpars tra_clpars tra
build_clpars raw_clpars dig
build_clpars rec_clpars rec
build_clpars tra_qa_clpars tra.qa
build_clpars raw_qa_clpars dig.qa
build_clpars rec_qa_clpars rec.qa

qa_clpars=(
    "--partition=$partition"
    "--export=ALL,TASK_RANGE=$TASK_RANGE"
    "--kill-on-invalid-dep=yes"
    "--job-name=${job_name}_qa"
    "--mem-per-cpu=$ram"
    "--time=$CFG_TIME"
    "--output=${log_dir}/%j.qa.log"
)

# ---------------------------------------------------------------------------
# Submit Slurm jobs
# ---------------------------------------------------------------------------

declare -a full_qa_dependencies=()
declare -a submitted_job_ids=()

if "$RUN_TRA"; then
    tra_id=$(sbatch --parsable \
        "${tra_clpars[@]}" \
        "${SCRIPT_DIR}/sbash/$tra_exe")

    echo "Stage Transport: $tra_id"
    full_qa_dependencies+=("$tra_id")
    submitted_job_ids+=("$tra_id")

    raw_clpars+=("--dependency=aftercorr:$tra_id")
    if "$RUN_STEP_QA"; then
        tra_qa_id=$(sbatch --parsable \
            "${tra_qa_clpars[@]}" \
            "--dependency=aftercorr:$tra_id" \
            "${SCRIPT_DIR}/sbash/$tra_qa_exe")
        echo "Stage Transport QA: $tra_qa_id"
        submitted_job_ids+=("$tra_qa_id")
    fi
fi

if "$RUN_DIG"; then
    raw_id=$(sbatch --parsable \
        "${raw_clpars[@]}" \
        "${SCRIPT_DIR}/sbash/$raw_exe")

    echo "Stage Digitization: $raw_id"
    full_qa_dependencies+=("$raw_id")
    submitted_job_ids+=("$raw_id")

    rec_clpars+=("--dependency=aftercorr:$raw_id")
    if "$RUN_STEP_QA"; then
        raw_qa_id=$(sbatch --parsable \
            "${raw_qa_clpars[@]}" \
            "--dependency=aftercorr:$raw_id" \
            "${SCRIPT_DIR}/sbash/$raw_qa_exe")
        echo "Stage Digitization QA: $raw_qa_id"
        submitted_job_ids+=("$raw_qa_id")
    fi
fi

if "$RUN_REC"; then
    rec_id=$(sbatch --parsable \
        "${rec_clpars[@]}" \
        "${SCRIPT_DIR}/sbash/$rec_exe")

    echo "Stage Reconstruction: $rec_id"
    full_qa_dependencies+=("$rec_id")
    submitted_job_ids+=("$rec_id")

    if "$RUN_STEP_QA"; then
        rec_qa_id=$(sbatch --parsable \
            "${rec_qa_clpars[@]}" \
            "--dependency=aftercorr:$rec_id" \
            "${SCRIPT_DIR}/sbash/$rec_qa_exe")
        echo "Stage Reconstruction QA: $rec_qa_id"
        submitted_job_ids+=("$rec_qa_id")
    fi
fi

if "$RUN_QA"; then
    if (( ${#full_qa_dependencies[@]} > 0 )); then
        full_qa_dependency=$(IFS=:; echo "${full_qa_dependencies[*]}")
        qa_clpars+=("--dependency=afterok:$full_qa_dependency")
    fi
    qa_id=$(sbatch --parsable \
        "${qa_clpars[@]}" \
        "${SCRIPT_DIR}/sbash/$qa_exe")

    echo "Stage QA: $qa_id"
    submitted_job_ids+=("$qa_id")
fi

if [[ "${CBM_RUN_SNAPSHOT:-false}" == true && ${#submitted_job_ids[@]} -gt 0 ]]; then
    cleanup_dependency=$(IFS=:; echo "${submitted_job_ids[*]}")
    cleanup_args=(
        "--partition=$partition"
        "--export=ALL,CBM_RUN_SNAPSHOT_DIR=$SCRIPT_DIR"
        "--dependency=afterany:$cleanup_dependency"
        "--job-name=${job_name}_cleanup"
        "--mem-per-cpu=1G"
        "--time=00:05:00"
        "--output=${log_dir}/%j.cleanup.log"
    )
    if "$debug_mode"; then
        cleanup_args+=("${SCRIPT_DIR}/sbash/cleanup.sbash" --debug)
    else
        cleanup_args+=("${SCRIPT_DIR}/sbash/cleanup.sbash")
    fi
    cleanup_id=$(sbatch --parsable "${cleanup_args[@]}")
    echo "Stage Cleanup: $cleanup_id"
fi

# ---------------------------------------------------------------------------
# Slurm queue summary
# ---------------------------------------------------------------------------

print_queue_summary() {
    local total running pending dep_wait dep_failed other_pending

    total=$(squeue -h -u "$USER" | wc -l)
    running=$(squeue -h -u "$USER" -t RUNNING | wc -l)
    pending=$(squeue -h -u "$USER" -t PENDING | wc -l)

    dep_wait=$(
        squeue -h -u "$USER" -t PENDING -o "%r" |
            grep -c '^Dependency$' || true
    )

    dep_failed=$(
        squeue -h -u "$USER" -t PENDING -o "%r" |
            grep -c '^DependencyNeverSatisfied$' || true
    )

    other_pending=$((pending - dep_wait - dep_failed))

    cat <<EOF
================ Queue Summary ================
User:              $USER
Total jobs:        $total
Running:           $running
Pending:           $pending
Pending reasons:
  Waiting dependency:      $dep_wait
  Failed dependency:       $dep_failed
  Other:                   $other_pending
===============================================
EOF
}

print_queue_summary
