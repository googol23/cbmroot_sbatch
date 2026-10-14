#!/usr/bin/env bash

set -o pipefail

USER="${USER:-$(id -un)}"
export USER

# ---------------------------------------------------------------------------
# Script location
# ---------------------------------------------------------------------------
# All pipeline scripts are expected to live in the same directory as this
# file. This makes the complete pipeline directory relocatable.
#
# BASH_SOURCE[0] points to run_common.sh even when this file is sourced from
# another script.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

CBM_RUN_DIR="${CBM_RUN_DIR:-$SCRIPT_DIR}"
export CBM_RUN_DIR

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

require_file() {
  local file="$1"
  local description="$2"

  if [[ ! -f "$file" || ! -r "$file" ]]; then
    error "${description} is missing or unreadable: ${file}"
    exit 1
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    error "Required command was not found: ${command_name}"
    exit 1
  fi
}

run_command() {
  log "Running: $*"

  if "$@"; then
    return 0
  else
    local status=$?
    error "Command failed with exit code ${status}: $*"
    exit "$status"
  fi
}

run_logged_command() {
  local log_file="$1"
  shift

  # A subshell lets us report both execution and redirection failures to
  # the stage's stderr, while keeping program output in the stage log.
  if (run_command "$@") > "$log_file" 2>&1; then
    return 0
  else
    local status=$?
    error "Stage command failed with exit code ${status}; log: ${log_file}"
    exit "$status"
  fi
}

# ---------------------------------------------------------------------------
# Slurm job information
# ---------------------------------------------------------------------------
JOB_ID="${SLURM_JOB_ID:?SLURM_JOB_ID is not defined. Run this script through Slurm or run_jobs.sh --local.}"
TASK_ID="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is not defined. Run this script through Slurm or run_jobs.sh --local.}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
: "${CFG_CBMROOT_SETUP:?Submit this job through run_jobs.sh}"
: "${CFG_INPUT_DIR:?Missing run input directory}"
: "${CFG_OUTPUT_DIR:?Missing run output directory}"
: "${CFG_TRA_CONFIG:?Missing transport configuration}"
: "${CFG_RAW_CONFIG:?Missing digitization configuration}"
: "${CFG_REC_CONFIG:?Missing reconstruction configuration}"
: "${CFG_QA_CONFIG:?Missing QA configuration}"
: "${CFG_SETUP_TAG:?Missing setup tag}"
: "${CFG_NEVENTS:?Missing event count}"

require_file "$CFG_CBMROOT_SETUP" "CBMROOT setup file"
if source "$CFG_CBMROOT_SETUP" -o; then
  :
else
  setup_status=$?
  error "CBMROOT setup failed with exit code ${setup_status}: ${CFG_CBMROOT_SETUP}"
  exit "$setup_status"
fi

if [[ -z "${VMCWORKDIR:-}" || "$VMCWORKDIR" != /* || ! -d "$VMCWORKDIR" ]]; then
  error "CBMROOT setup did not provide an existing absolute VMCWORKDIR: ${VMCWORKDIR:-unset}"
  exit 1
fi

NEVENTS="$CFG_NEVENTS"
SETUP_TAG="$CFG_SETUP_TAG"
INPUT_DIR="$CFG_INPUT_DIR"
OUTPUT_DIR="$CFG_OUTPUT_DIR"
SLURM_DIR="$CBM_RUN_DIR"

CBMROOT_DIR="${VMCWORKDIR%/}"
if [[ "$CBMROOT_DIR" != */share/cbmroot ]]; then
  error "Expected an installed CBMROOT environment ending in /share/cbmroot: ${VMCWORKDIR}"
  exit 1
fi
CBMROOT_DIR="${CBMROOT_DIR%share/cbmroot}"

log "SCRIPT_DIR: ${SCRIPT_DIR}"
log "OUTPUT_DIR: ${OUTPUT_DIR}"
log "CBMROOT_DIR: ${CBMROOT_DIR}"

TRA_CONFIG_FILE="$CFG_TRA_CONFIG"
RAW_CONFIG_FILE="$CFG_RAW_CONFIG"
REC_CONFIG_FILE="$CFG_REC_CONFIG"
QA_CONFIG_FILE="$CFG_QA_CONFIG"

ROOT="root -l -q -b"

TRANSPORT_BIN="${CBMROOT_DIR}/bin/cbmsim_transport"
DIGITIZATION_BIN="${CBMROOT_DIR}/bin/cbmsim_digitization"
RECONSTRUCTION_BIN="${CBMROOT_DIR}/bin/cbmreco_offline"

RECONSTRUCTION_MACRO="${VMCWORKDIR}/macro/run/run_reco.C"

QA_TRANSPORT_MACRO="${CBM_RUN_DIR}/macros/run_tra_qa.C"
QA_DIGITIZATION_MACRO="${CBM_RUN_DIR}/macros/run_raw_qa.C"
QA_RECONSTRUCTION_MACRO="${CBM_RUN_DIR}/macros/run_rec_qa.C"

# ---------------------------------------------------------------------------
# Input and output files
# ---------------------------------------------------------------------------
INPUT_FILE="${INPUT_DIR}/dcmqgsm_${TASK_ID}.root"

TRANSPORT_OUT_DIR="${OUTPUT_DIR}/tra/${TASK_ID}"
DIGITIZATION_OUT_DIR="${OUTPUT_DIR}/raw/${TASK_ID}"
RECONSTRUCTION_OUT_DIR="${OUTPUT_DIR}/rec/${TASK_ID}"
QA_OUT_DIR="${OUTPUT_DIR}/qa/${TASK_ID}"

TRANSPORT_OUTPUT="${TRANSPORT_OUT_DIR}/${TASK_ID}.tra.root"
TRANSPORT_PARMET="${TRANSPORT_OUT_DIR}/${TASK_ID}.par.root"
TRANSPORT_LOG="${TRANSPORT_OUT_DIR}/transport.log"

DIGITIZATION_OUTPUT="${DIGITIZATION_OUT_DIR}/${TASK_ID}.digi.root"
DIGITIZATION_PARMET="${DIGITIZATION_OUT_DIR}/${TASK_ID}.par.root"
DIGITIZATION_LOG="${DIGITIZATION_OUT_DIR}/digitization.log"

RECONSTRUCTION_OUTPUT="${RECONSTRUCTION_OUT_DIR}/${TASK_ID}.reco.root"
RECONSTRUCTION_PARMET="${RECONSTRUCTION_OUT_DIR}/${TASK_ID}.par.root"
RECONSTRUCTION_LOG="${RECONSTRUCTION_OUT_DIR}/reconstruction.log"

QA_TRANSPORT_OUTPUT="${QA_OUT_DIR}/${TASK_ID}.tra.qa.root"
QA_TRANSPORT_LOG="${QA_OUT_DIR}/${TASK_ID}.tra.qa.log"
QA_DIGITIZATION_OUTPUT="${QA_OUT_DIR}/${TASK_ID}.digi.qa.root"
QA_DIGITIZATION_LOG="${QA_OUT_DIR}/${TASK_ID}.digi.qa.log"
QA_RECONSTRUCTION_OUTPUT="${QA_OUT_DIR}/${TASK_ID}.reco.qa.root"
QA_RECONSTRUCTION_LOG="${QA_OUT_DIR}/${TASK_ID}.reco.qa.log"

run_command mkdir -p -- \
  "$TRANSPORT_OUT_DIR" "$DIGITIZATION_OUT_DIR" \
  "$RECONSTRUCTION_OUT_DIR" "$QA_OUT_DIR"

log "Slurm/local job ID: ${JOB_ID}"
log "Task ID: ${TASK_ID}"
log "Input file: ${INPUT_FILE}"
log "Output base: ${OUTPUT_DIR}"

log " **********************"
log " **** I/O Settings ****"
log " **********************"
log "TRANSPORT_OUTPUT: ${TRANSPORT_OUTPUT}"
log "TRANSPORT_PARMET: ${TRANSPORT_PARMET}"
log "DIGITIZATION_OUTPUT: ${DIGITIZATION_OUTPUT}"
log "DIGITIZATION_PARMET: ${DIGITIZATION_PARMET}"
log "RECONSTRUCTION_OUTPUT: ${RECONSTRUCTION_OUTPUT}"
log "RECONSTRUCTION_PARMET: ${RECONSTRUCTION_PARMET}"
log "QA_TRANSPORT_OUTPUT: ${QA_TRANSPORT_OUTPUT}"
log "QA_DIGITIZATION_OUTPUT: ${QA_DIGITIZATION_OUTPUT}"
log "QA_RECONSTRUCTION_OUTPUT: ${QA_RECONSTRUCTION_OUTPUT}"
