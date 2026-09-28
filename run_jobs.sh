#!/usr/bin/env bash
set -euo pipefail
USER="${USER:-$(id -un)}"
export USER

usage() {
    cat <<'EOF'
Usage: ./run_jobs.sh [run_config.yaml] [OPTIONS]
  -t, --transport       Submit transport
  -d, --digitization    Submit digitization
  -r, --reconstruction  Submit reconstruction
      --qa              Submit QA
  -j, --jobs RANGE      Slurm array range
      --test            Submit the success test script instead
      --dc              Retained for compatibility (currently unused)
  -h, --help            Show this help
Stage flags replace the YAML stage list when any are supplied.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
config_file=""
declare -a selected_stages=()
jobs_override=""
test_override=false

while (( $# )); do
    case "$1" in
        -t|--transport) selected_stages+=(transport); shift ;;
        -d|--digitization) selected_stages+=(digitization); shift ;;
        -r|--reconstruction) selected_stages+=(reconstruction); shift ;;
        --qa) selected_stages+=(qa); shift ;;
        --test) test_override=true; shift ;;
        -j|--jobs)
            if (( $# < 2 )); then echo "$1 requires a range" >&2; exit 2; fi
            jobs_override="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -n "$config_file" ]]; then
                echo "Only one configuration file is allowed" >&2; exit 2
            fi
            config_file="$1"; shift ;;
    esac
done

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

RUN_TRA=false RUN_DIG=false RUN_REC=false RUN_QA=false
if [[ "$explicit_config" == true && ${#selected_stages[@]} -eq 0 ]]; then
    IFS=',' read -ra selected_stages <<< "$CFG_STAGES"
fi
for stage in "${selected_stages[@]}"; do
    case "$stage" in
        transport) RUN_TRA=true ;;
        digitization) RUN_DIG=true ;;
        reconstruction) RUN_REC=true ;;
        qa) RUN_QA=true ;;
    esac
done
TASK_RANGE="${jobs_override:-$CFG_TASK_RANGE}"
if [[ ! "$TASK_RANGE" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
    echo "Invalid Slurm array range: $TASK_RANGE" >&2; exit 2
fi
PIPELINE_TEST="$CFG_PIPELINE_TEST"
if "$test_override"; then PIPELINE_TEST=true; fi

job_name="$CFG_JOB_NAME"
partition="$CFG_PARTITION"
ram="$CFG_MEM_PER_CPU"
log_dir="$CFG_LOG_DIR"

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
build_clpars qa_clpars qa

if "$PIPELINE_TEST"; then
    tra_exe=success.sbash raw_exe=success.sbash rec_exe=success.sbash qa_exe=success.sbash
else
    tra_exe=run_tra.sbash raw_exe=run_raw.sbash rec_exe=run_rec.sbash qa_exe=run_qa.sbash
fi

if "$RUN_TRA"; then
    tra_id=$(sbatch --parsable "${tra_clpars[@]}" "${SCRIPT_DIR}/$tra_exe")
    echo "Stage Transport: $tra_id"
    raw_clpars+=("--dependency=aftercorr:$tra_id")
fi
if "$RUN_DIG"; then
    raw_id=$(sbatch --parsable "${raw_clpars[@]}" "${SCRIPT_DIR}/$raw_exe")
    echo "Stage Digitization: $raw_id"
    rec_clpars+=("--dependency=aftercorr:$raw_id")
fi
if "$RUN_REC"; then
    rec_id=$(sbatch --parsable "${rec_clpars[@]}" "${SCRIPT_DIR}/$rec_exe")
    echo "Stage Reconstruction: $rec_id"
fi
if "$RUN_QA"; then
    qa_id=$(sbatch --parsable "${qa_clpars[@]}" "${SCRIPT_DIR}/$qa_exe")
    echo "Stage QA: $qa_id"
fi

print_queue_summary() {
    local total running pending dep_wait dep_failed other_pending
    total=$(squeue -h -u "$USER" | wc -l)
    running=$(squeue -h -u "$USER" -t RUNNING | wc -l)
    pending=$(squeue -h -u "$USER" -t PENDING | wc -l)
    dep_wait=$(squeue -h -u "$USER" -t PENDING -o "%r" | grep -c '^Dependency$' || true)
    dep_failed=$(squeue -h -u "$USER" -t PENDING -o "%r" | grep -c '^DependencyNeverSatisfied$' || true)
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
