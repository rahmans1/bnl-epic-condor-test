#!/bin/bash
# Background-only mixed run, one chunk, one step:
#
#   bgmix_payload.sh merge   <chunk> <run_dir> <work_dir>   (merger container)
#   bgmix_payload.sh simreco <chunk> <run_dir> <work_dir>   (sim/reco container)
#   bgmix_payload.sh gunevgen <chunk> <run_dir> <work_dir>  (gun overlay: the signal)
#
# job.sh runs the two steps, each in its own container, on one scratch
# directory (work_dir), and copies the outputs out. The merger can then come
# from a newer image (TimeFrameBuilder is in eic_xl 26.08.0 and later) while
# npsim and eicrecon stay on the campaign release in both modes.
#
# Modelled on the epicprod payload (swf-epicprod/swf_epicprod/payload/run.sh):
# the merger runs through the production adapters, copied unchanged into
# mergers/ (hepmcmerger.sh, timeframebuilder.sh), with run.sh's normalized
# arguments: the same rate-scaled, seed-mixed background skips, the same
# status offsets handed to npsim, the same npsim/eicrecon flags. Everything
# PanDA- and Rucio-specific is left out.
#
# No physics signal: the merger's "signal" is a low-rate background run at its
# real frequency (> 0, so it is drawn from a Poisson rate like a background).
set -Euo pipefail

STEP=${1:?step: merge or simreco}
CHUNK=${2:?chunk index}
RUN_DIR=${3:?run directory}
WORK=${4:?work directory}
source "${RUN_DIR}/run.env"
HERE=$(dirname "$(realpath "$0")")

TASK=$(printf '%04d' "${CHUNK}")
# Seed as run.sh: chunk + 1. The same seeds in both merger modes, so a chunk
# of one mode pairs with the same chunk of the other.
SEED=$((10#${CHUNK} + 1))
# Gun overlay (gun/submit_gun.sh -B): the gun is the merger's signal, one
# particle per frame (frequency 0), written per chunk by the gunevgen step.
# The seed is the gun's, as run.sh (stem hash * 10000 + chunk + 1), so each
# particle draws its own gun kinematics, background skips and Geant4 stream.
if [ "${GUN_OVERLAY:-0}" = 1 ]; then
  GUN_STEM_HASH=$(printf '%s' "${SAMPLE}" | sha256sum | cut -c1-7)
  SEED=$(( (16#${GUN_STEM_HASH} * 10000 + 10#${CHUNK} + 1) % 2147483647 ))
  [ ${SEED} -gt 0 ] || SEED=1
fi
TASKNAME=${SAMPLE}.${TASK}
LOG_TEMP=${WORK}/LOG; FULL_TEMP=${WORK}/FULL; RECO_TEMP=${WORK}/RECO
mkdir -p "${LOG_TEMP}" "${FULL_TEMP}" "${RECO_TEMP}"
STAGES_LOG=${LOG_TEMP}/${TASKNAME}.stages.log
MERGED=${FULL_TEMP}/${TASKNAME}.hepmc3.tree.root
[ "${GUN_OVERLAY:-0}" = 1 ] && SIGNAL_FILE=${WORK}/${TASKNAME}.gun.hepmc3
cd "${WORK}"

CURRENT_STAGE=""
stage() {
  CURRENT_STAGE=$1
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1 $2${3:+ $3}" | tee -a "${STAGES_LOG}"
}
trap 's=$?; echo "$0: error on line $LINENO: $BASH_COMMAND"; [ -n "$CURRENT_STAGE" ] && stage "$CURRENT_STAGE" fail "line $LINENO exit $s"; exit $s' ERR
# As run.sh: each program runs under its own prmon when there is one.
monitor() {
  local label=$1; shift
  if command -v prmon >/dev/null 2>&1; then
    prmon --filename "${LOG_TEMP}/${TASKNAME}.${label}.prmon.txt" \
          --json-summary "${LOG_TEMP}/${TASKNAME}.${label}.prmon.json" \
          --log-filename "${LOG_TEMP}/${TASKNAME}.${label}.prmon.log" \
          --interval "${PRMON_INTERVAL:-1}" -- "$@"
  else
    "$@"
  fi
}

# Status lists for npsim, as run.sh: signal and each background, +1 stable,
# +2 decay. Both steps need them, so they are rebuilt from the same inputs.
STABLE_STATUSES="$((SIGNAL_STATUS + 1))"
DECAY_STATUSES="$((SIGNAL_STATUS + 2))"
while read -r st; do
  STABLE_STATUSES="${STABLE_STATUSES} $((st + 1))"
  DECAY_STATUSES="${DECAY_STATUSES} $((st + 2))"
done < <(jq -r '.[].status' "${RUN_DIR}/backgrounds.json")

merge() {
  # MERGER_PATH (optional, run.env): a directory put first on PATH for the
  # merge step, e.g. a locally patched timeframe_builder build.
  if [ -n "${MERGER_PATH:-}" ]; then export PATH=${MERGER_PATH}:${PATH}; echo "merger from ${MERGER_PATH}"; fi
  echo "merge step: ${MERGER} in $(cat /etc/jug_info 2>/dev/null | head -1 || echo "${MERGER_CONTAINER}")"
  ADAPTER=${HERE}/mergers/${MERGER}.sh
  [ -f "${ADAPTER}" ] || { echo "ERROR: unknown MERGER ${MERGER}"; exit 86; }
  BIN=$(bash "${ADAPTER}" --binary)
  command -v "${BIN}" >/dev/null || { echo "ERROR: ${BIN} not in ${MERGER_CONTAINER}"; exit 86; }

  # Background skips, as run.sh: rate-scaled advance plus a seed-driven
  # random offset (both mergers repeat background files at end of file).
  BASENAME_HASH=$(( 16#$(printf '%s' "${SAMPLE}" | sha256sum | cut -c1-8) ))
  MIXED_SEED=$(( (BASENAME_HASH << 20) + SEED ))
  SKIP_N_FRAMES=$((10#${CHUNK} * FRAMES))
  BG_ARGS=()
  while read -r row; do
    file=$(jq -r '.file' <<<"${row}")
    freq=$(jq -r '.freq' <<<"${row}")
    status=$(jq -r '.status' <<<"${row}")
    per_frame=$(awk "BEGIN {print (${freq})*(${INTEGRATION_WINDOW})*1e-6}")
    skip=$(awk "BEGIN {srand(${MIXED_SEED}); print int((${SKIP_N_FRAMES}*${per_frame})+1) + int(rand()*2147483647)}")
    BG_ARGS+=(--background "${file}" "${freq}" "${skip}" "${status}")
  done < <(jq -c '.[]' "${RUN_DIR}/backgrounds.json")

  # The signal file is not repeated (SignalBackgroundMerger never wraps it;
  # the TimeFrameBuilder adapter gives the signal no repeat), so each chunk
  # reads its own block of SIGNAL_BLOCK events (submit.sh: Poisson headroom,
  # and the range checked against the file). Unlike run.sh's chunk * frames,
  # which assumes one signal event per frame.
  SIGNAL_SKIP=$((10#${CHUNK} * SIGNAL_BLOCK))

  stage background start "${MERGER}, ${FRAMES} frames, signal skip ${SIGNAL_SKIP}"
  {
    date
    eic-info 2>/dev/null | head -5 || true
    monitor "${MERGER}" bash "${ADAPTER}" \
      --seed "${SEED}" \
      --frames "${FRAMES}" \
      --window "${INTEGRATION_WINDOW}" \
      --output "${MERGED}" \
      --signal "${SIGNAL_FILE}" "${SIGNAL_FREQ}" "${SIGNAL_SKIP}" "${SIGNAL_STATUS}" \
      "${BG_ARGS[@]}"
  } 2>&1 | tee "${LOG_TEMP}/${TASKNAME}.${MERGER}.log" | tail -n 200
  # A merger can stop short and still exit 0 (TimeFrameBuilder at the end of
  # a source without repeat), so the frames are counted (as run.sh).
  MERGED_FRAMES=$(python3 -c '
import sys, ROOT
f = ROOT.TFile.Open(sys.argv[1]); t = f.Get("hepmc3_tree")
print(t.GetEntries() if t else "")' "${MERGED}" 2>/dev/null | tail -1) || MERGED_FRAMES=""
  if [ "${MERGED_FRAMES}" != "${FRAMES}" ]; then
    stage background fail "merged file holds ${MERGED_FRAMES:-no readable} frames of ${FRAMES}"
    exit 87
  fi
  stage background ok "${MERGER}, ${MERGED_FRAMES} frames"
}

simreco() {
  [ -s "${MERGED}" ] || { echo "ERROR: no merged file ${MERGED}"; exit 87; }
  # thisepic.sh reads positional arguments and sets DETECTOR_CONFIG, so it
  # is sourced with none and the requested configuration restored (run.sh).
  DETECTOR_CONFIG_REQUESTED=${DETECTOR_CONFIG}
  set --
  source /opt/detector/epic-${DETECTOR_VERSION}/bin/thisepic.sh
  export DETECTOR_CONFIG=${DETECTOR_CONFIG_REQUESTED}
  export DETECTOR_COMPACT=${DETECTOR_PATH}/${DETECTOR_CONFIG}_${EBEAM}x${PBEAM}.xml
  [ -f "${DETECTOR_COMPACT}" ] || { echo "ERROR: no geometry ${DETECTOR_COMPACT}"; exit 83; }

  # Simulation: run.sh's common and hepmc flags; the merged file is not skipped.
  stage simulation start "${FRAMES} frames"
  {
    date
    eic-info 2>/dev/null | head -5 || true
    monitor npsim npsim \
      --random.seed "${SEED}" \
      --random.enableEventSeed \
      --printLevel WARNING \
      --filter.tracker 'edep0' \
      --numberOfEvents "${FRAMES}" \
      --compactFile "${DETECTOR_COMPACT}" \
      --outputFile "${FULL_TEMP}/${TASKNAME}.edm4hep.root" \
      --runType batch \
      --skipNEvents 0 \
      --hepmc3.useHepMC3 true \
      --physics.alternativeStableStatuses "${STABLE_STATUSES}" \
      --physics.alternativeDecayStatuses "${DECAY_STATUSES}" \
      --inputFiles "${MERGED}"
    ls -al "${FULL_TEMP}/${TASKNAME}.edm4hep.root"
  } 2>&1 | tee "${LOG_TEMP}/${TASKNAME}.npsim.log" | tail -n 200
  stage simulation ok

  # Reconstruction: run.sh's eicrecon flags.
  stage reconstruction start
  {
    date
    monitor eicrecon eicrecon \
      -Pdd4hep:xml_files="${DETECTOR_COMPACT}" \
      -Ppodio:output_file="${RECO_TEMP}/${TASKNAME}.eicrecon.edm4eic.root" \
      -Pjana:warmup_timeout=0 -Pjana:timeout=0 \
      "${FULL_TEMP}/${TASKNAME}.edm4hep.root"
    ls -al "${RECO_TEMP}/${TASKNAME}.eicrecon.edm4eic.root"
  } 2>&1 | tee "${LOG_TEMP}/${TASKNAME}.eicrecon.log" | tail -n 200
  stage reconstruction ok
}

# Gun overlay: the chunk's gun events, one per frame, as HepMC3 ASCII
# (gun/gun_hepmc.py; the template's kinematics).
gunevgen() {
  stage evgen start "${FRAMES} ${GUN_PARTICLE} at ${GUN_ENERGY_GEV} GeV, ${GUN_THETA_MIN}-${GUN_THETA_MAX} deg, seed ${SEED}"
  python3 "${HERE}/gun/gun_hepmc.py" --particle "${GUN_PARTICLE}" --energy-gev "${GUN_ENERGY_GEV}" \
    --theta-min "${GUN_THETA_MIN}" --theta-max "${GUN_THETA_MAX}" \
    --events "${FRAMES}" --seed "${SEED}" --output "${SIGNAL_FILE}" \
    2>&1 | tee "${LOG_TEMP}/${TASKNAME}.gunevgen.log"
  [ -s "${SIGNAL_FILE}" ] || { stage evgen fail "no gun file"; exit 82; }
  stage evgen ok
}

# Benchmark (submit.sh -X): reduce the merged file to bench/extract.py's
# summary, under the step's own prmon.
extract() {
  [ -s "${MERGED}" ] || { echo "ERROR: no merged file ${MERGED}"; exit 87; }
  STATUSES=$(jq -r --argjson s "${SIGNAL_STATUS}" '[$s] + [.[].status] | map(tostring) | join(",")' "${RUN_DIR}/backgrounds.json")
  stage extract start "statuses ${STATUSES}"
  monitor extract python3 "${HERE}/bench/extract.py" "${MERGED}" "${WORK}/${TASKNAME}.bench.npz" "${STATUSES}" \
    2>&1 | tee "${LOG_TEMP}/${TASKNAME}.extract.log" | tail -n 50
  stage extract ok
}

case "${STEP}" in
  merge) merge ;;
  simreco) simreco ;;
  extract) extract ;;
  gunevgen) gunevgen ;;
  *) echo "unknown step ${STEP}"; exit 2 ;;
esac
