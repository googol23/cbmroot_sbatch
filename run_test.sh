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
source /lustre/cbm/users/dramirez/CBMROOT_260630/install/bin/CbmRootConfig.sh -o
INPUT_DIR="/lustre/cbm/pwg/common/mc/generators/dcmqgsm_smm/auau/pbeam12agev/mbias/root"
OUTPUT_DIR="/lustre/cbm/users/${USER}/mc/out"
CONFIG_FILE="/lustre/cbm/users/${USER}/slurm_scripts/traConfig.yaml"

export TRANSPORT_BIN="${VMCWORKDIR%share/cbmroot}/bin/cbmsim_transport"
export DIGITIZATION_BIN="${VMCWORKDIR%share/cbmroot}/bin/cbmsim_digitization"
export RECONSTRUCTION_BIN="${VMCWORKDIR%share/cbmroot}/bin/cbmreco"

# ---------------------------------------------------------------------------
# Input and output files
# ---------------------------------------------------------------------------
INPUT_FILE="${INPUT_DIR}/dcmqgsm_${TASK_ID}.root"

OUTPUT_BASE="${OUTPUT_DIR}/${TASK_ID}"
TRANSPORT_OUTPUT="${OUTPUT_BASE}.tra.root"
PARAMETER_OUTPUT="${OUTPUT_BASE}.par.root"
DIGITIZATION_OUTPUT="${OUTPUT_BASE}.raw.root"
RECONSTRUCTION_OUTPUT="${OUTPUT_BASE}.reco.root"

mkdir -p "$OUTPUT_DIR"

log "Slurm job ID: ${JOB_ID}"
log "Slurm array task ID: ${TASK_ID}"
log "Input file: ${INPUT_FILE}"
log "Configuration file: ${CONFIG_FILE}"
log "Output base: ${OUTPUT_BASE}"

# ---------------------------------------------------------------------------
# Validate requirements
# ---------------------------------------------------------------------------

require_file "$INPUT_FILE" "Generator input file"
require_file "$CONFIG_FILE" "Configuration file"

require_command "$TRANSPORT_BIN"
require_command "$DIGITIZATION_BIN"
require_command "$RECONSTRUCTION_BIN"

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

log "Starting transport simulation."

run_command "$TRANSPORT_BIN" \
  -i "unigen=${INPUT_FILE}" \
  -o "$TRANSPORT_OUTPUT" \
  -c "$CONFIG_FILE" \
  -s "sis100_electron" \
  -n 999 \
  -w

require_file "$TRANSPORT_OUTPUT" "Transport output file"
require_file "$PARAMETER_OUTPUT" "Transport parameter file"

log "Transport completed: ${TRANSPORT_OUTPUT}"

# ---------------------------------------------------------------------------
# Digitization
# ---------------------------------------------------------------------------

log "Starting digitization."

# run_command "$DIGITIZATION_BIN" \
#   -t "$TRANSPORT_OUTPUT" \
#   -p "$PARAMETER_OUTPUT" \
#   -o "$DIGITIZATION_OUTPUT" \
#   -c "$CONFIG_FILE" \
#   -w

require_file "$DIGITIZATION_OUTPUT" "Digitization output file"

log "Digitization completed: ${DIGITIZATION_OUTPUT}"

# ---------------------------------------------------------------------------
# Reconstruction
# ---------------------------------------------------------------------------

log "Starting reconstruction."

# run_command "$RECONSTRUCTION_BIN" \
#   -i "$DIGITIZATION_OUTPUT" \
#   -p "$PARAMETER_OUTPUT" \
#   -o "$RECONSTRUCTION_OUTPUT" \
#   -c "$CONFIG_FILE" \
#   -s "$SETUP_TAG" \
#   -n "$NEVENTS" \
#   -w

require_file "$RECONSTRUCTION_OUTPUT" "Reconstruction output file"

log "Reconstruction completed: ${RECONSTRUCTION_OUTPUT}"
log "Full simulation chain completed successfully."
