#!/bin/bash
# Condor executable: one chunk of a background-only or file run. The merge
# step (skipped in a plain file run), simulation and reconstruction all run
# in the run's one image, on one scratch directory; the outputs and the stage
# logs are copied to OUT_DIR.
# Usage: job.sh <chunk> <run_dir>
set -uo pipefail
CHUNK=$1
RUN_DIR=$2
source "${RUN_DIR}/run.env"
HERE=$(dirname "$(realpath "$0")")
TASKNAME=${SAMPLE}.$(printf '%04d' "${CHUNK}")
if [ "${PLAIN:-0}" = 1 ]; then RUN_KIND="plain file (no merge)"; else RUN_KIND="merger ${MERGER}"; fi
echo "date: $(date)  host: $(hostname -f)  ${RUN_KIND}  image: $(basename "${CONTAINER}")"

# Outputs already there: a resubmitted chunk that finished has nothing to do.
RECO_OUT=${OUT_DIR}/RECO/${TASKNAME}.eicrecon.edm4eic.root
BENCH_OUT=${OUT_DIR}/BENCH/${TASKNAME}.bench.npz
if [ "${MERGE_ONLY:-0}" = 1 ]; then RECO_OUT=${BENCH_OUT}; fi
if [ -s "${RECO_OUT}" ] && [ "${OVERWRITE:-0}" != 1 ]; then
  echo "${RECO_OUT} exists; nothing to do (OVERWRITE=1 to redo)."
  exit 0
fi

SCRATCH=${_CONDOR_SCRATCH_DIR:-${TMPDIR:-/tmp}}
WORK=${SCRATCH}/bgmix-${TASKNAME}-$$
mkdir -p "${WORK}/LOG"
# On every exit: the stage logs go to OUT_DIR/LOG, then the scratch is
# removed (KEEP_SCRATCH=1 keeps it).
finish() {
  mkdir -p "${OUT_DIR}/LOG" && tar -czf "${OUT_DIR}/LOG/${TASKNAME}.log.tar.gz" -C "${WORK}/LOG" . || true
  [ "${KEEP_SCRATCH:-0}" = 1 ] || rm -rf "${WORK}"
}
trap finish EXIT

run_in() {
  local image=$1; shift
  apptainer exec --cleanenv -B /gpfs02,/gpfs/mnt/gpfs02,"${SCRATCH}" \
    "${image}" bash "${HERE}/bgmix_payload.sh" "$@" "${CHUNK}" "${RUN_DIR}" "${WORK}"
}

# A plain file run (file/submit_file.sh, PLAIN=1) has no merge: npsim reads
# the generator file itself.
if [ "${PLAIN:-0}" != 1 ]; then
  run_in "${MERGER_CONTAINER}" merge || exit $?
fi
if [ "${MERGE_ONLY:-0}" = 1 ]; then
  # Benchmark: the merged file's summary instead of simulation (bench/).
  run_in "${CONTAINER}" extract || exit $?
  mkdir -p "${OUT_DIR}/BENCH"
  cp "${WORK}/${TASKNAME}.bench.npz" "${BENCH_OUT}.part" && mv "${BENCH_OUT}.part" "${BENCH_OUT}" || exit 89
  if [ "${KEEP_MERGED:-0}" = 1 ]; then
    mkdir -p "${OUT_DIR}/HEPMC" && cp "${WORK}/FULL/${TASKNAME}.hepmc3.tree.root" "${OUT_DIR}/HEPMC/" || exit 89
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) output ok ${BENCH_OUT}" | tee -a "${WORK}/LOG/${TASKNAME}.stages.log"
  exit 0
fi
run_in "${CONTAINER}" simreco || exit $?

# Copy out: RECO always, FULL and the merged HepMC on request.
mkdir -p "${OUT_DIR}/RECO"
cp "${WORK}/RECO/${TASKNAME}.eicrecon.edm4eic.root" "${RECO_OUT}.part" && mv "${RECO_OUT}.part" "${RECO_OUT}" || exit 89
if [ "${KEEP_FULL:-0}" = 1 ]; then
  mkdir -p "${OUT_DIR}/FULL" && cp "${WORK}/FULL/${TASKNAME}.edm4hep.root" "${OUT_DIR}/FULL/" || exit 89
fi
if [ "${KEEP_MERGED:-0}" = 1 ]; then
  mkdir -p "${OUT_DIR}/HEPMC" && cp "${WORK}/FULL/${TASKNAME}.hepmc3.tree.root" "${OUT_DIR}/HEPMC/" || exit 89
fi
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) output ok ${RECO_OUT}" | tee -a "${WORK}/LOG/${TASKNAME}.stages.log"
