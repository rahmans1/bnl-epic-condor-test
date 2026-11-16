#!/bin/bash
# Condor executable for one particle-gun chunk. A plain gun runs
# gun_payload.sh in CONTAINER. An overlay (GUN_OVERLAY=1) runs bgmix_payload.sh's
# gunevgen, merge and simreco steps. Both run on scratch, then copy RECO
# (FULL with -F, the merged HepMC with -H) to OUT_DIR.
# Usage: gun/gun_job.sh <chunk> <run_dir>
set -uo pipefail
CHUNK=$1
RUN_DIR=$2
source "${RUN_DIR}/run.env"
HERE=$(dirname "$(realpath "$0")")
TASKNAME=${SAMPLE}.$(printf '%04d' "${CHUNK}")
echo "date: $(date)  host: $(hostname -f)  gun: ${SAMPLE}"

RECO_OUT=${OUT_DIR}/RECO/${TASKNAME}.eicrecon.edm4eic.root
if [ -s "${RECO_OUT}" ] && [ "${OVERWRITE:-0}" != 1 ]; then
  echo "${RECO_OUT} exists; nothing to do (OVERWRITE=1 to redo)."
  exit 0
fi

SCRATCH=${_CONDOR_SCRATCH_DIR:-${TMPDIR:-/tmp}}
WORK=${SCRATCH}/gun-${TASKNAME}-$$
mkdir -p "${WORK}/LOG"
finish() {
  mkdir -p "${OUT_DIR}/LOG" && tar -czf "${OUT_DIR}/LOG/${TASKNAME}.log.tar.gz" -C "${WORK}/LOG" . || true
  [ "${KEEP_SCRATCH:-0}" = 1 ] || rm -rf "${WORK}"
}
trap finish EXIT

if [ "${GUN_OVERLAY:-0}" = 1 ]; then
  # Overlay: the gun file, the merge (the gun as signal, one per frame, plus
  # every background), then simulation and reconstruction of the merged
  # frames. These are bgmix_payload.sh's steps, run as in the background-only job.
  run_bg() {
    local image=$1; shift
    apptainer exec --cleanenv -B /gpfs02,/gpfs/mnt/gpfs02,"${SCRATCH}" \
      "${image}" bash "${TOP}/bgmix_payload.sh" "$1" "${CHUNK}" "${RUN_DIR}" "${WORK}"
  }
  TOP=$(dirname "${HERE}")
  run_bg "${CONTAINER}" gunevgen || exit $?
  run_bg "${MERGER_CONTAINER}" merge || exit $?
  run_bg "${CONTAINER}" simreco || exit $?
else
  apptainer exec --cleanenv -B /gpfs02,/gpfs/mnt/gpfs02,"${SCRATCH}" \
    "${CONTAINER}" bash "${HERE}/gun_payload.sh" "${CHUNK}" "${RUN_DIR}" "${WORK}" || exit $?
fi

mkdir -p "${OUT_DIR}/RECO"
cp "${WORK}/RECO/${TASKNAME}.eicrecon.edm4eic.root" "${RECO_OUT}.part" && mv "${RECO_OUT}.part" "${RECO_OUT}" || exit 89
if [ "${KEEP_FULL:-0}" = 1 ]; then
  mkdir -p "${OUT_DIR}/FULL" && cp "${WORK}/FULL/${TASKNAME}.edm4hep.root" "${OUT_DIR}/FULL/" || exit 89
fi
if [ "${KEEP_MERGED:-0}" = 1 ] && [ "${GUN_OVERLAY:-0}" = 1 ]; then
  mkdir -p "${OUT_DIR}/HEPMC" && cp "${WORK}/FULL/${TASKNAME}.hepmc3.tree.root" "${OUT_DIR}/HEPMC/" || exit 89
fi
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) output ok ${RECO_OUT}" | tee -a "${WORK}/LOG/${TASKNAME}.stages.log"
