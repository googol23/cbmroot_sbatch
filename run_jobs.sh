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
      --qa              Submit/run QA
  -j, --jobs RANGE      Slurm/local task range
      --test            Run the success test script instead
      --local           Run jobs locally instead of submitting to Slurm
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
  LOCAL_MAX_JOBS=2 ./run_jobs.sh config.yaml -t -d -r -j 1-10 --local
EOF
}

remote_exec_warning() {
    cat <<'EOF'
Oe estas a punto de estallar to esta pinga.
Syncroniza esta pinga
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

config_file=""
declare -a selected_stages=()
jobs_override=""
test_override=false
local_mode=false

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
        --test)
            test_override=true
            shift
            ;;
        --local)
            local_mode=true
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
            shift
            ;;
    esac
done


# ---------------------------------------------------------------------------
# Host determination
# ---------------------------------------------------------------------------
if ! "$local_mode"; then
  if [[ "$(hostname)" == "lxi"* ]]; then
    remote_exec_warning
    read -p "Are you sure? [y/n]" -n 1 -r
    echo    # (optional) move to a new line
  
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo "Esta talla se va a conectar a VIRGO"
      
      SYNC_PATH=/lustre/cbm/users/dramirez/slurm_scripts_v3/
      read -p "Quieres sync los codigos feos estos a ${SYNC_PATH}? [y/n]" -n 1 -r
      echo    # (optional) move to a new line
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        ./sync.sh ${SYNC_PATH}
      fi

      echo "#ssh "${USER}@vae25-virgo4.hpc.gsi.de" "bash ${SYNC_PATH}/run_jobs.sh $*@""
      ssh "${USER}@vae25-virgo4.hpc.gsi.de" "bash ${SYNC_PATH}/run_jobs.sh $*@"
      exit 0
    else
      exit 1
    fi
  fi
fi
echo "Mi gente, tamo en Japon..."
hostname
exit 1
# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
explicit_config=false

if [[ -n "$config_file" ]]; then
    explicit_config=true
else
    config_file="${SCRIPT_DIR}/default_config.yaml"
fi

CBM_RUN_DIR="$SCRIPT_DIR"
export CBM_RUN_DIR

settings="$(python3 "${SCRIPT_DIR}/config_loader.py" "$config_file")" || exit 1

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
PIPELINE_TEST="$CFG_PIPELINE_TEST"

if "$test_override"; then
    PIPELINE_TEST=true
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
else
    tra_exe=run_tra.sbash
    raw_exe=run_raw.sbash
    rec_exe=run_rec.sbash
    qa_exe=run_qa.sbash
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
                "${SCRIPT_DIR}/${tra_exe}"
                echo "[local:${task_id}] Transport completed"
            fi

            if "$RUN_DIG"; then
                echo "[local:${task_id}] Starting Digitization"
                "${SCRIPT_DIR}/${raw_exe}"
                echo "[local:${task_id}] Digitization completed"
            fi

            if "$RUN_REC"; then
                echo "[local:${task_id}] Starting Reconstruction"
                "${SCRIPT_DIR}/${rec_exe}"
                echo "[local:${task_id}] Reconstruction completed"
            fi

            if "$RUN_QA"; then
                echo "[local:${task_id}] Starting QA"
                "${SCRIPT_DIR}/${qa_exe}"
                echo "[local:${task_id}] QA completed"
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
    echo "QA:                  $RUN_QA"
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

if "$RUN_TRA"; then
    tra_id=$(sbatch --parsable \
        "${tra_clpars[@]}" \
        "${SCRIPT_DIR}/$tra_exe")

    echo "Stage Transport: $tra_id"

    raw_clpars+=("--dependency=aftercorr:$tra_id")
fi

if "$RUN_DIG"; then
    raw_id=$(sbatch --parsable \
        "${raw_clpars[@]}" \
        "${SCRIPT_DIR}/$raw_exe")

    echo "Stage Digitization: $raw_id"

    rec_clpars+=("--dependency=aftercorr:$raw_id")
fi

if "$RUN_REC"; then
    rec_id=$(sbatch --parsable \
        "${rec_clpars[@]}" \
        "${SCRIPT_DIR}/$rec_exe")

    echo "Stage Reconstruction: $rec_id"
fi

if "$RUN_QA"; then
    qa_id=$(sbatch --parsable \
        "${qa_clpars[@]}" \
        "${SCRIPT_DIR}/$qa_exe")

    echo "Stage QA: $qa_id"
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
