#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================================================
# Colors
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

SUCCESS_PATTERN="Macro finished successfully."

usage() {
    cat <<EOF
Usage:
    $0 <qa_output_dir> <task_range>

Examples:
    $0 /lustre/cbm/users/\${USER}/mc/out/qa "1-20"
    $0 /lustre/cbm/users/\${USER}/mc/out/qa "1,3,7-10"

Expected log layout:
    <qa_output_dir>/<task_id>/<task_id>.qa.log

Example:
    /lustre/cbm/users/\${USER}/mc/out/qa/17/17.qa.log
EOF
}

# ============================================================================
# Arguments
# ============================================================================
if (( $# != 2 )); then
    usage
    exit 1
fi

QA_BASE_DIR="$1"
TASK_RANGE="$2"

if [[ ! -d "${QA_BASE_DIR}" ]]; then
    printf "${RED}ERROR:${RESET} QA output directory does not exist: %s\n" \
        "${QA_BASE_DIR}"
    exit 1
fi

# ============================================================================
# Expand task range
#
# Supported:
#   1
#   1-10
#   1,4,7
#   1-5,10,20-25
# ============================================================================
expand_task_range() {
    local specification="$1"
    local part
    local start
    local end

    IFS=',' read -ra parts <<< "${specification}"

    for part in "${parts[@]}"; do
        if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"

            if (( start > end )); then
                printf 'Invalid range: %s\n' "${part}" >&2
                return 1
            fi

            seq "${start}" "${end}"

        elif [[ "${part}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "${part}"

        else
            printf 'Invalid task specification: %s\n' "${part}" >&2
            return 1
        fi
    done
}

mapfile -t TASK_IDS < <(expand_task_range "${TASK_RANGE}")

if (( ${#TASK_IDS[@]} == 0 )); then
    printf "${RED}ERROR:${RESET} No task IDs found.\n"
    exit 1
fi

# ============================================================================
# Check jobs
# ============================================================================
successful_jobs=()
failed_jobs=()

for task_id in "${TASK_IDS[@]}"; do
    log_file="${QA_BASE_DIR}/${task_id}/${task_id}.qa.log"

    if [[ ! -f "${log_file}" ]]; then
        failed_jobs+=("${task_id}|LOG MISSING|${log_file}")
        continue
    fi

    if grep -Fq "${SUCCESS_PATTERN}" "${log_file}"; then
        successful_jobs+=("${task_id}|OK|${log_file}")
    else
        failed_jobs+=("${task_id}|MACRO DID NOT FINISH|${log_file}")
    fi
done

total=${#TASK_IDS[@]}
successful=${#successful_jobs[@]}
failed=${#failed_jobs[@]}

# ============================================================================
# Summary
# ============================================================================
printf '\n'
printf "${BOLD}${CYAN}============================================================${RESET}\n"
printf "${BOLD}                     QA JOB SUMMARY${RESET}\n"
printf "${BOLD}${CYAN}============================================================${RESET}\n"
printf " Jobs checked : ${BOLD}%d${RESET}\n" "${total}"
printf " Successful   : ${GREEN}${BOLD}%d${RESET}\n" "${successful}"
printf " Failed       : ${RED}${BOLD}%d${RESET}\n" "${failed}"
printf "${BOLD}${CYAN}============================================================${RESET}\n"

# ============================================================================
# Detailed status
# ============================================================================
printf '\n'
printf "${BOLD}QA JOB DETAILS${RESET}\n"
printf '%s\n' "------------------------------------------------------------"

if (( failed > 0 )); then
    printf "\n${RED}${BOLD}FAILED JOBS${RESET}\n"

    for entry in "${failed_jobs[@]}"; do
        IFS='|' read -r task_id reason log_file <<< "${entry}"

        printf "  ${RED}${RESET} Task %-6s  ${RED}FAILED${RESET}  (%s)\n" \
            "${task_id}" "${reason}"
        printf "      %s\n" "${log_file}"
    done
else
    printf "\n${GREEN}${BOLD}FAILED JOBS${RESET}\n"
    printf "  ${GREEN}None${RESET}\n"
fi

printf '\n'

if (( successful > 0 )); then
    printf "${GREEN}${BOLD}SUCCESSFUL JOBS${RESET}\n"

    for entry in "${successful_jobs[@]}"; do
        IFS='|' read -r task_id reason log_file <<< "${entry}"

        printf "  ${GREEN}${RESET} Task %-6s  ${GREEN}OK${RESET}\n" \
            "${task_id}"
    done
else
    printf "${GREEN}${BOLD}SUCCESSFUL JOBS${RESET}\n"
    printf "  None\n"
fi

printf '\n'
printf '%s\n' "------------------------------------------------------------"

# Useful when calling this script from another script:
#   0 = all checked jobs succeeded
#   1 = at least one job failed
if (( failed > 0 )); then
    exit 1
fi

exit 0