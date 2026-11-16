#!/bin/bash
# The merger benchmark (bench/README.md), in two steps:
#
#   bench/run_benchmark.sh submit  [RUNS_DIR]   # Condor: both mergers, merge only
#   bench/run_benchmark.sh analyze [RUNS_DIR]   # after every job has ended
#
# RUNS_DIR defaults to bench/runs. Results go to bench/results (RESULTS=...).
# CONFIG, CHUNKS, FRAMES and SCALING may be set in the environment.
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
TOP=$(dirname "${HERE}")
STEP=${1:?submit or analyze}
RUNS=$(realpath -m "${2:-${HERE}/runs}")
RESULTS=$(realpath -m "${RESULTS:-${HERE}/results}")
CONFIG=${CONFIG:-${TOP}/configs/allbg_10x275_gold10um.env}
CHUNKS=${CHUNKS:-20}
FRAMES=${FRAMES:-500}
SCALING=${SCALING:-100 1000}
SCALING_CHUNKS=${SCALING_CHUNKS:-3}
source "${CONFIG}"
# Analysis image: uproot, scipy and matplotlib (the sim/reco image).
IMAGE=${IMAGE:-${CONTAINER}}

case "${STEP}" in
  submit)
    for m in hepmcmerger timeframebuilder; do
      "${TOP}/submit.sh" -c "${CONFIG}" -n "${CHUNKS}" -f "${FRAMES}" -M "${m}" -X -o "${RUNS}/f${FRAMES}"
      for f in ${SCALING}; do
        "${TOP}/submit.sh" -c "${CONFIG}" -n "${SCALING_CHUNKS}" -f "${f}" -M "${m}" -X -o "${RUNS}/f${f}"
      done
    done
    echo "submitted; run '$0 analyze ${RUNS}' when condor_q shows none of these jobs"
    ;;
  analyze)
    MAIN=${RUNS}/f${FRAMES}/${SAMPLE}
    SCALE=()
    for f in ${SCALING}; do
      for m in hepmcmerger timeframebuilder; do
        [ -d "${RUNS}/f${f}/${SAMPLE}/bench-${m}" ] && SCALE+=("${RUNS}/f${f}/${SAMPLE}/bench-${m}")
      done
    done
    mkdir -p "${RESULTS}"
    apptainer exec --cleanenv -B /gpfs02,/gpfs/mnt/gpfs02,"${RESULTS}" "${IMAGE}" bash -c "
      set -e
      python3 '${HERE}/source_info.py' '${MAIN}/bench-hepmcmerger' '${RESULTS}/source_info.json'
      python3 '${HERE}/compare.py' --a '${MAIN}/bench-hepmcmerger' --b '${MAIN}/bench-timeframebuilder' \
        --sources '${RESULTS}/source_info.json' --scaling ${SCALE[*]+${SCALE[*]}} --out '${RESULTS}'"
    ;;
  *) echo "unknown step ${STEP}"; exit 2 ;;
esac
