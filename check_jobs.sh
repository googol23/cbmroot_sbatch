#!/usr/bin/env bash

set -u
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
readonly SUCCESS_PATTERN='Macro finished successfully.'

DETAILED=false
SELECTED_STAGES='all'
JOBS='auto'

usage() {
    cat <<EOF
Usage:
    $(basename "$0") [OPTIONS] <output_root> <task_range>

Check one or more processing stages below a common output directory.

Arguments:
    output_root    Directory containing tra/, raw/, reco/, and/or qa/
    task_range     Task IDs such as 1, 1-20, or 1,3,7-10

Options:
    -s, --stage STAGES   Stages to check: all, tra, raw, reco, qa
                         Multiple stages may be comma-separated.
                         Default: all
    -d, --detailed       List failed and successful tasks for every stage
    -j, --jobs N         Number of parallel checks, or 'auto' (default)
                         Auto uses available CPUs, capped at 16 for Lustre.
        --no-color       Disable colored output
    -h, --help           Show this help

Examples:
    $(basename "$0") /lustre/cbm/users/\${USER}/mc/out '1-99'
    $(basename "$0") --stage tra /lustre/cbm/users/\${USER}/mc/out '1-99'
    $(basename "$0") -d -j 8 -s raw,reco,qa /lustre/cbm/users/\${USER}/mc/out '1,3,7-10'

Expected logs:
    tra/<task_id>/transport.log.gz
    raw/<task_id>/digitization.log.gz
    reco/<task_id>/reconstruction.log.gz
    qa/<task_id>/<task_id>.qa.log

Exit status:
    0  Every checked task succeeded
    1  At least one task failed or has no log
    2  Invalid arguments or configuration
EOF
}

error() {
    printf '%bERROR:%b %s\n' "${RED}" "${RESET}" "$*" >&2
}

while (( $# > 0 )); do
    case "$1" in
        -s|--stage)
            if (( $# < 2 )); then
                error "$1 requires a value."
                usage >&2
                exit 2
            fi
            SELECTED_STAGES="$2"
            shift 2
            ;;
        --stage=*)
            SELECTED_STAGES="${1#*=}"
            shift
            ;;
        -d|--detailed)
            DETAILED=true
            shift
            ;;
        -j|--jobs)
            if (( $# < 2 )); then
                error "$1 requires a value."
                usage >&2
                exit 2
            fi
            JOBS="$2"
            shift 2
            ;;
        --jobs=*)
            JOBS="${1#*=}"
            shift
            ;;
        --no-color)
            RED=''
            GREEN=''
            YELLOW=''
            CYAN=''
            BOLD=''
            RESET=''
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            error "Unknown option: $1"
            usage >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if (( $# != 2 )); then
    error 'Expected <output_root> and <task_range>.'
    usage >&2
    exit 2
fi

OUTPUT_ROOT="${1%/}"
TASK_RANGE="$2"

if [[ ! -d "$OUTPUT_ROOT" ]]; then
    error "Output root does not exist: $OUTPUT_ROOT"
    exit 2
fi

if [[ "$JOBS" == 'auto' ]]; then
    if command -v nproc >/dev/null 2>&1; then
        JOBS="$(nproc)"
    else
        JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
    fi
    # More workers can overload a shared filesystem's metadata server.
    (( JOBS > 16 )) && JOBS=16
elif [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    error "--jobs must be a positive integer or 'auto'."
    exit 2
fi

expand_task_range() {
    local specification="$1"
    local part start end
    local -a parts

    IFS=',' read -ra parts <<< "$specification"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if (( 10#$start > 10#$end )); then
                printf 'Invalid descending range: %s\n' "$part" >&2
                return 1
            fi
            seq "$((10#$start))" "$((10#$end))"
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            printf '%d\n' "$((10#$part))"
        else
            printf 'Invalid task specification: %s\n' "$part" >&2
            return 1
        fi
    done
}

if ! TASK_OUTPUT="$(expand_task_range "$TASK_RANGE")"; then
    exit 2
fi
mapfile -t TASK_IDS <<< "$TASK_OUTPUT"
if (( ${#TASK_IDS[@]} == 0 )) || [[ -z "${TASK_IDS[0]}" ]]; then
    error 'No task IDs found.'
    exit 2
fi

declare -A STAGE_DIR=(
    [tra]='tra'
    [raw]='raw'
    [reco]='reco'
    [qa]='qa'
)
declare -A STAGE_LABEL=(
    [tra]='TRANSPORT'
    [raw]='DIGITIZATION'
    [reco]='RECONSTRUCTION'
    [qa]='QA'
)
declare -A FAILURE_REASON=(
    [tra]='TRANSPORT DID NOT FINISH'
    [raw]='DIGITIZATION DID NOT FINISH'
    [reco]='RECONSTRUCTION DID NOT FINISH'
    [qa]='QA DID NOT FINISH'
)

if [[ "$SELECTED_STAGES" == 'all' ]]; then
    STAGES=(tra raw reco qa)
else
    IFS=',' read -ra STAGES <<< "$SELECTED_STAGES"
fi

if (( ${#STAGES[@]} == 0 )); then
    error 'No stages selected.'
    exit 2
fi

declare -A seen_stages=()
for stage in "${STAGES[@]}"; do
    if [[ -z "${STAGE_DIR[$stage]+x}" ]]; then
        error "Unknown stage '$stage'. Valid stages: all, tra, raw, reco, qa."
        exit 2
    fi
    if [[ -n "${seen_stages[$stage]+x}" ]]; then
        error "Stage '$stage' was selected more than once."
        exit 2
    fi
    seen_stages[$stage]=1
done

log_path() {
    local stage="$1" task_id="$2" base_dir="$3"
    case "$stage" in
        tra)  printf '%s/%s/transport.log.gz' "$base_dir" "$task_id" ;;
        raw)  printf '%s/%s/digitization.log.gz' "$base_dir" "$task_id" ;;
        reco) printf '%s/%s/reconstruction.log.gz' "$base_dir" "$task_id" ;;
        qa)   printf '%s/%s/%s.qa.log' "$base_dir" "$task_id" "$task_id" ;;
    esac
}

log_contains_success() {
    local log_file="$1"
    if [[ "$log_file" == *.gz ]]; then
        # Do not use grep -q here: an early grep exit can give gzip SIGPIPE
        # and produce a false failure when pipefail is enabled.
        gzip -cd -- "$log_file" 2>/dev/null | grep -F -- "$SUCCESS_PATTERN" >/dev/null
        local -a pipeline_status=("${PIPESTATUS[@]}")
        (( pipeline_status[0] == 0 && pipeline_status[1] == 0 ))
    else
        grep -Fq -- "$SUCCESS_PATTERN" "$log_file"
    fi
}

check_one_task() {
    local item="$1"
    local stage="${item%%|*}"
    local task_id="${item#*|}"
    local base_dir="$OUTPUT_ROOT/${STAGE_DIR[$stage]}"
    local file

    file="$(log_path "$stage" "$task_id" "$base_dir")"
    if [[ ! -f "$file" ]]; then
        printf '%s|%s|FAILED|LOG MISSING|%s\n' "$stage" "$task_id" "$file"
    elif log_contains_success "$file"; then
        printf '%s|%s|OK|OK|%s\n' "$stage" "$task_id" "$file"
    else
        printf '%s|%s|FAILED|%s|%s\n' \
            "$stage" "$task_id" "${FAILURE_REASON[$stage]}" "$file"
    fi
}

print_stage_report() {
    local stage="$1" total="$2" successful="$3" failed="$4"
    local -n successes_ref="$5"
    local -n failures_ref="$6"
    local entry task_id reason file

    printf '\n%b============================================================%b\n' "${BOLD}${CYAN}" "$RESET"
    printf '%b%28s JOB SUMMARY%b\n' "$BOLD" "${STAGE_LABEL[$stage]}" "$RESET"
    printf '%b============================================================%b\n' "${BOLD}${CYAN}" "$RESET"
    printf ' Jobs checked : %b%d%b\n' "$BOLD" "$total" "$RESET"
    printf ' Successful   : %b%b%d%b\n' "$GREEN" "$BOLD" "$successful" "$RESET"
    printf ' Failed       : %b%b%d%b\n' "$RED" "$BOLD" "$failed" "$RESET"
    printf '%b============================================================%b\n' "${BOLD}${CYAN}" "$RESET"

    if ! $DETAILED; then
        return
    fi

    printf '\n%b%s JOB DETAILS%b\n' "$BOLD" "${STAGE_LABEL[$stage]}" "$RESET"
    printf '%s\n' '------------------------------------------------------------'
    printf '\n%b%bFAILED JOBS%b\n' "$RED" "$BOLD" "$RESET"
    if (( failed == 0 )); then
        printf '  %bNone%b\n' "$GREEN" "$RESET"
    else
        for entry in "${failures_ref[@]}"; do
            IFS='|' read -r task_id reason file <<< "$entry"
            printf '  Task %-6s  %bFAILED%b  (%s)\n' "$task_id" "$RED" "$RESET" "$reason"
            printf '      %s\n' "$file"
        done
    fi

    printf '\n%b%bSUCCESSFUL JOBS%b\n' "$GREEN" "$BOLD" "$RESET"
    if (( successful == 0 )); then
        printf '  None\n'
    else
        for entry in "${successes_ref[@]}"; do
            IFS='|' read -r task_id reason file <<< "$entry"
            printf '  Task %-6s  %bOK%b\n' "$task_id" "$GREEN" "$RESET"
        done
    fi
    printf '%s\n' '------------------------------------------------------------'
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-jobs.XXXXXXXX")" || {
    error 'Could not create a temporary working directory.'
    exit 2
}
cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
RESULT_FILE="$WORK_DIR/results"

# Export the worker and its dependencies for the Bash processes started by
# xargs. Each worker emits exactly one result record; only the parent aggregates.
export OUTPUT_ROOT SUCCESS_PATTERN
export -f log_path log_contains_success check_one_task
declare -p STAGE_DIR FAILURE_REASON > "$WORK_DIR/worker-state"

work_items=()
for stage in "${STAGES[@]}"; do
    for task_id in "${TASK_IDS[@]}"; do
        work_items+=("$stage|$task_id")
    done
done

# Never start more processes than there are checks.
(( JOBS > ${#work_items[@]} )) && JOBS=${#work_items[@]}

printf '%s\0' "${work_items[@]}" |
    xargs -0 -r -n 1 -P "$JOBS" bash -c \
        'source "$1"; check_one_task "$2"' _ "$WORK_DIR/worker-state" \
        > "$RESULT_FILE"
xargs_status=$?
if (( xargs_status != 0 )); then
    error "Parallel worker execution failed (xargs status $xargs_status)."
    exit 2
fi

expected_results=${#work_items[@]}
actual_results=$(wc -l < "$RESULT_FILE")
if (( actual_results != expected_results )); then
    error "Expected $expected_results results, but collected $actual_results."
    exit 2
fi

overall_failed=0
total_checks=0
total_successful=0

for stage in "${STAGES[@]}"; do
    successful_jobs=()
    failed_jobs=()

    while IFS='|' read -r result_stage task_id status reason file; do
        [[ "$result_stage" == "$stage" ]] || continue
        if [[ "$status" == 'OK' ]]; then
            successful_jobs+=("$task_id|$reason|$file")
        else
            failed_jobs+=("$task_id|$reason|$file")
        fi
    done < <(sort -t '|' -k2,2n "$RESULT_FILE")

    stage_total=${#TASK_IDS[@]}
    stage_successful=${#successful_jobs[@]}
    stage_failed=${#failed_jobs[@]}
    print_stage_report "$stage" "$stage_total" "$stage_successful" "$stage_failed" \
        successful_jobs failed_jobs

    total_checks=$((total_checks + stage_total))
    total_successful=$((total_successful + stage_successful))
    overall_failed=$((overall_failed + stage_failed))
done

if (( ${#STAGES[@]} > 1 )); then
    printf '\n%b%bOVERALL: %d/%d checks successful; %d failed.%b\n\n' \
        "$BOLD" "$CYAN" "$total_successful" "$total_checks" "$overall_failed" "$RESET"
else
    printf '\n'
fi

if (( overall_failed > 0 )); then
    exit 1
fi
exit 0
