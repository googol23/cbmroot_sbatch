#!/usr/bin/env bash
set -euo pipefail

print_queue_summary() {
    local total running pending dep_wait dep_failed other_pending

    total=$(squeue -h -u "${USER}" | wc -l)

    running=$(squeue -h -u "${USER}" -t RUNNING | wc -l)

    pending=$(squeue -h -u "${USER}" -t PENDING | wc -l)

    dep_wait=$(squeue -h -u "${USER}" -t PENDING -o "%r" \
        | grep -c '^Dependency$' || true)

    dep_failed=$(squeue -h -u "${USER}" -t PENDING -o "%r" \
        | grep -c '^DependencyNeverSatisfied$' || true)

    other_pending=$((pending - dep_wait - dep_failed))

    cat <<EOF
================ Queue Summary ================
User:              ${USER}

Total jobs:        ${total}
Running:           ${running}
Pending:           ${pending}

Pending reasons:
  Waiting dependency:      ${dep_wait}
  Failed dependency:       ${dep_failed}
  Other:                   ${other_pending}
===============================================
EOF
}

PIPELINE_TEST=false
DEAD_CHANNELS=false
RUN_TRA=false
RUN_DIG=false
RUN_REC=false
RUN_QA=false
TASK_RANGE='1-1'

while [[ $# -gt 0 ]]; do
  case $1 in
    --test)
      PIPELINE_TEST=true
      shift # past argument
      ;;
    -t|--transport)
      RUN_TRA=true
      shift # past argument
      ;;
    -d|--digitization)
      RUN_DIG=true
      shift # past argument
      ;;
    -r|--reconstruction)
      RUN_REC=true
      shift # past argument
      ;;
    --qa)
      RUN_QA=true
      shift # past argument
      ;;
    --dc)
      DEAD_CHANNELS=true
      shift # past argument
      ;;
    -j|--jobs)
      TASK_RANGE="$2"
      shift
      shift
      ;;
  esac
done

job_name="cbmsim"
partition="long"
ram="64G"

log_dir="/lustre/cbm/users/${USER}/mc/log"
mkdir -pv "${log_dir}"

build_clpars() {
    local -n result=$1
    local stage=$2
    local time=$3

    result=(
        "--partition=${partition}"
        "--array=${TASK_RANGE}"
        "--export=ALL"
        "--kill-on-invalid-dep=yes"
        "--job-name=${job_name}_${stage}"
        "--mem-per-cpu=${ram}"
        "--time=${time}"
        "--output=${log_dir}/%a_%A.${stage}.log"
    )
}

build_clpars tra_clpars "tra" "02:00:00"
build_clpars qa_tra_clpars "qa_tra" "02:00:00"
build_clpars raw_clpars "dig" "02:00:00"
build_clpars qa_raw_clpars "qa_raw" "02:00:00"
build_clpars merge_raw_clpars "merge_raw" "02:00:00"
build_clpars rec_clpars "rec" "02:00:00"
build_clpars qa_rec_clpars "qa_rec" "02:00:00"

build_clpars qa_clpars "qa" "02:00:00"

summary_clpars=(
    "--partition=${partition}"
    "--export=ALL"
    "--job-name=${job_name}_summary"
    "--mem-per-cpu=${ram}"
    "--time=02:00:00"
    "--output=${log_dir}/%a_%A.summary.log"
)

if ${PIPELINE_TEST}; then
    tra_exe="success.sbash"
    raw_exe="success.sbash"
    rec_exe="success.sbash"
    qa_exe="success.sbash"
    summary_exe="success.sbash"
else
    tra_exe="run_tra.sbash"
    raw_exe="run_raw.sbash"
    rec_exe="run_rec.sbash"
    qa_exe="run_qa.sbash"
    summary_exe="failure.sbash"
fi

if ${RUN_TRA}; then
    tra_id=$(sbatch --parsable \
        "${tra_clpars[@]}" \
        "${tra_exe}")
    echo "Stage Transport: $tra_id"

    raw_clpars+=("--dependency=aftercorr:${tra_id}")
fi

if ${RUN_DIG}; then
    raw_id=$(sbatch --parsable \
        "${raw_clpars[@]}" \
        "${raw_exe}")
    echo "Stage Digitization: $raw_id"

    rec_clpars+=("--dependency=aftercorr:${raw_id}")
fi

if ${RUN_REC}; then
    rec_id=$(sbatch --parsable \
        "${rec_clpars[@]}" \
        "${rec_exe}")
    echo "Stage Reconstruction: $rec_id"
fi

if ${RUN_QA}; then
    qa_id=$(sbatch --parsable \
          "${qa_clpars[@]}" \
          "${qa_exe}")
  
    echo "Stage QA: $qa_id"
    # summary_deps=""

    # if ${RUN_TRA}; then
    #     summary_deps+=":${tra_id}"
    # fi

    # if ${RUN_DIG}; then
    #     summary_deps+=":${raw_id}"
    # fi

    # if ${RUN_REC}; then
    #     summary_deps+=":${rec_id}"
    # fi

    # if [ -n "${summary_deps}" ]; then
    #     summary_clpars+=("--dependency=afterany${summary_deps}")
    #     summary_id=$(sbatch --parsable \
    #         "${summary_clpars[@]}" \
    #         "${summary_exe}")
    #     echo "Stage Summary: $summary_id"
    # fi
fi

print_queue_summary
