#!/usr/bin/env bash

set -o pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

require_file() {
  local file="$1"
  local description="$2"

  if [[ ! -f "$file" ]]; then
    error "${description} does not exist: ${file}"
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

  "$@"
  local status=$?

  if (( status != 0 )); then
    error "Command failed with exit code ${status}: $*"
    exit "$status"
  fi
}

# ---------------------------------------------------------------------------
# Slurm job information
# ---------------------------------------------------------------------------
JOB_ID="${SLURM_JOB_ID:?SLURM_JOB_ID is not defined. Run this script through Slurm.}"
TASK_ID="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is not defined. Submit this script as a Slurm array job.}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
source /lustre/cbm/users/${USER}/CBMROOT_260819/install/bin/CbmRootConfig.sh -o

NEVENTS=999

SETUP_TAG="sis100_electron"
INPUT_DIR="/lustre/cbm/pwg/common/mc/generators/dcmqgsm_smm/auau/pbeam12agev/mbias/root"
OUTPUT_DIR="/lustre/cbm/users/${USER}/mc/out"
SLURM_DIR="/lustre/cbm/users/${USER}/slurm_scripts"
CBMROOT_DIR="${VMCWORKDIR%share/cbmroot}"

log "OUTPUT_DIR: ${OUTPUT_DIR}"
log "CBMROOT_DIR: ${CBMROOT_DIR}"

TRA_CONFIG_FILE="${SLURM_DIR}/traConfig.yaml"
RAW_CONFIG_FILE="${SLURM_DIR}/rawConfig.yaml"
REC_CONFIG_FILE="${SLURM_DIR}/recConfig.yaml"

ROOT="root -l -q -b"

TRANSPORT_BIN="${CBMROOT_DIR}/bin/cbmsim_transport"
DIGITIZATION_BIN="${CBMROOT_DIR}/bin/cbmsim_digitization"
RECONSTRUCTION_BIN="${CBMROOT_DIR}/bin/cbmreco_offline"
RECONSTRUCTION_MACRO="${VMCWORKDIR}//macro/run/run_reco.C"

QA_TRANSPORT_MACRO="${CBMROOT_DIR}/macro/run/run_qaTra.C"
QA_DIGITIZATION_MACRO="${CBMROOT_DIR}/macro/TODO"
QA_RECONSTRUCTION_MACRO="${CBMROOT_DIR}/macro/TODO"
QA_SUMMARY_MACRO="${CBMROOT_DIR}/macro/TODO"

QA_MACRO=${VMCWORKDIR}/macro/run/run_qa.C

# ---------------------------------------------------------------------------
# Input and output files
# ---------------------------------------------------------------------------
INPUT_FILE="${INPUT_DIR}/dcmqgsm_${TASK_ID}.root"

TRANSPORT_OUT_DIR="${OUTPUT_DIR}/tra/${TASK_ID}"
DIGITIZATION_OUT_DIR="${OUTPUT_DIR}/raw/${TASK_ID}"
RECONSTRUCTION_OUT_DIR="${OUTPUT_DIR}/reco/${TASK_ID}"
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

QA_OUTPUT="${QA_OUT_DIR}/${TASK_ID}.qa.root"
QA_LOG="${QA_OUT_DIR}/${TASK_ID}.qa.log"

QA_TRANSPORT_OUTPUT="${TRANSPORT_OUT_DIR}/${TASK_ID}.tra.qa.root"
QA_DIGITIZATION_OUTPUT="${DIGITIZATION_OUT_DIR}/${TASK_ID}.digi.qa.root"
QA_DIGITIZATION_DC_OUTPUT="${DIGITIZATION_OUT_DIR}/${TASK_ID}_dc.digi.qa.root"
QA_RECONSTRUCTION_OUTPUT="${RECONSTRUCTION_OUT_DIR}/${TASK_ID}.reco.qa.root"
QA_RECONSTRUCTION_DC_OUTPUT="${RECONSTRUCTION_OUT_DIR}/${TASK_ID}_dc.reco.qa.root"
QA_SUMMARY_OUTPUT="${OUTPUT_DIR}/${TASK_ID}.qa.root"

mkdir -p "${TRANSPORT_OUT_DIR}"
mkdir -p "${DIGITIZATION_OUT_DIR}"
mkdir -p "${QA_OUT_DIR}"

log "Slurm job ID: ${JOB_ID}"
log "Slurm array task ID: ${TASK_ID}"
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
log "QA_OUTPUT: ${QA_OUTPUT}"