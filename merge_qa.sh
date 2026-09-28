#!/usr/bin/env bash

set -u
set -o pipefail

SUCCESS_PATTERN="Macro finished successfully."

usage() {
    cat <<EOF
Usage:
    $(basename "$0") [OPTIONS] <qa_dir> <task_range>

Options:
    -o, --output FILE      Output ROOT file (default: <qa_dir>/merged.root)
    -j, --jobs N           Parallel hadd jobs (default: 4)
    -m, --merger FILE      External merger: ROOT macro (.C) or executable
    -l, --file-list FILE   Keep the list of valid ROOT files
        --list-only        Generate file list without merging
    -h, --help             Show this help

Examples:
    $(basename "$0") /path/to/qa "1-100"

    $(basename "$0") -j 16 -o merged.root /path/to/qa "1-500"

    $(basename "$0") -m merge_qa.C /path/to/qa "1-100"

    $(basename "$0") --list-only -l files.txt /path/to/qa "1-100"
EOF
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
OUTPUT=""
MERGER=""
FILE_LIST=""
JOBS=4
LIST_ONLY=0

while (( $# )); do
    case "$1" in
        -o|--output)    OUTPUT="$2";    shift 2 ;;
        -j|--jobs)      JOBS="$2";      shift 2 ;;
        -m|--merger)    MERGER="$2";    shift 2 ;;
        -l|--file-list) FILE_LIST="$2"; shift 2 ;;
        --list-only)    LIST_ONLY=1;    shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
        *)              break ;;
    esac
done

(( $# == 2 )) || { usage; exit 1; }

QA_DIR="${1%/}"
TASK_RANGE="$2"
OUTPUT="${OUTPUT:-${QA_DIR}/merged.root}"

[[ -d "${QA_DIR}" ]] ||
    { echo "ERROR: Directory not found: ${QA_DIR}" >&2; exit 1; }

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] ||
    { echo "ERROR: --jobs must be a positive integer." >&2; exit 1; }

# -----------------------------------------------------------------------------
# Expand ranges such as:
#   1
#   1-10
#   1,3,7-10
# -----------------------------------------------------------------------------
expand_range() {
    local part start end

    IFS=',' read -ra parts <<< "$1"

    for part in "${parts[@]}"; do
        if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"

            (( start <= end )) ||
                { echo "ERROR: Invalid range: ${part}" >&2; return 1; }

            seq "${start}" "${end}"

        elif [[ "${part}" =~ ^[0-9]+$ ]]; then
            echo "${part}"

        else
            echo "ERROR: Invalid task: ${part}" >&2
            return 1
        fi
    done
}

mapfile -t TASKS < <(expand_range "${TASK_RANGE}")

(( ${#TASKS[@]} > 0 )) ||
    { echo "ERROR: No valid tasks." >&2; exit 1; }

# -----------------------------------------------------------------------------
# File list
# -----------------------------------------------------------------------------
TEMP_LIST=0

if [[ -z "${FILE_LIST}" ]]; then
    FILE_LIST="$(mktemp)"
    TEMP_LIST=1
else
    : > "${FILE_LIST}"
fi

cleanup() {
    (( TEMP_LIST )) && rm -f "${FILE_LIST}"
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Check jobs
# -----------------------------------------------------------------------------
ok=0
failed=0

echo
echo "Checking QA jobs"
echo "------------------------------------------------------------"

for task in "${TASKS[@]}"; do
    log="${QA_DIR}/${task}/${task}.qa.log"
    root="${QA_DIR}/${task}/${task}.qa.root"

    if [[ ! -f "${log}" ]]; then
        printf "Task %-6s FAILED  log missing\n" "${task}"
        ((failed++))
        continue
    fi

    if ! grep -Fq "${SUCCESS_PATTERN}" "${log}"; then
        printf "Task %-6s FAILED  macro did not finish\n" "${task}"
        ((failed++))
        continue
    fi

    if [[ ! -s "${root}" ]]; then
        printf "Task %-6s FAILED  ROOT file missing/empty\n" "${task}"
        ((failed++))
        continue
    fi

    printf "Task %-6s OK\n" "${task}"
    echo "${root}" >> "${FILE_LIST}"
    ((ok++))
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "------------------------------------------------------------"
printf "Checked    : %d\n" "${#TASKS[@]}"
printf "Successful : %d\n" "${ok}"
printf "Failed     : %d\n" "${failed}"

(( ok > 0 )) || {
    echo "ERROR: No valid ROOT files found." >&2
    exit 1
}

# -----------------------------------------------------------------------------
# List-only mode
# -----------------------------------------------------------------------------
if (( LIST_ONLY )); then
    (( TEMP_LIST == 0 )) || {
        echo "ERROR: --list-only requires --file-list FILE." >&2
        exit 1
    }

    echo "File list: ${FILE_LIST}"
    exit 0
fi

# -----------------------------------------------------------------------------
# Merge
# -----------------------------------------------------------------------------
echo
printf "Merging %d ROOT files -> %s\n" "${ok}" "${OUTPUT}"

if [[ -z "${MERGER}" ]]; then

    # Default merger
    command -v hadd >/dev/null ||
        { echo "ERROR: hadd not found." >&2; exit 1; }

    hadd -j "${JOBS}" -f "${OUTPUT}" @"${FILE_LIST}"

elif [[ "${MERGER}" == *.C ]]; then

    # ROOT macro interface:
    #
    #   void merge_qa(const char* fileList, const char* outputFile)
    #
    [[ -f "${MERGER}" ]] ||
        { echo "ERROR: Macro not found: ${MERGER}" >&2; exit 1; }

    root -l -b -q \
        "${MERGER}(\"${FILE_LIST}\",\"${OUTPUT}\")"

else

    # External executable interface:
    #
    #   merger file_list output.root
    #
    [[ -x "${MERGER}" ]] ||
        { echo "ERROR: Merger not executable: ${MERGER}" >&2; exit 1; }

    "${MERGER}" "${FILE_LIST}" "${OUTPUT}"
fi

status=$?

# -----------------------------------------------------------------------------
# Result
# -----------------------------------------------------------------------------
if (( status != 0 )); then
    echo "ERROR: Merge failed (status ${status})." >&2
    exit "${status}"
fi

echo
echo "Merge completed: ${OUTPUT}"

(( failed > 0 )) &&
    echo "WARNING: ${failed} failed jobs were excluded."

exit 0
