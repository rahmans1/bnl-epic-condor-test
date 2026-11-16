#!/bin/bash
# Submit particle-gun singles to BNL SDCC HTCondor. submit.sh calls this
# script when the config sets MODE=gun.
#
#   ./submit.sh -c configs/singles_20GeV_1to4deg.env [options]
#
#   -c FILE   gun configuration (configs/singles_*.env)
#   -n N      chunks per particle               [GUN_EVENTS / events per chunk]
#   -s N      first chunk index (to extend a run)                [0]
#   -e N      events per chunk         [EVENTS_PER_CHUNK, overlay OVERLAY_EVENTS_PER_CHUNK]
#   -p LIST   only these particles, space separated   [GUN_PARTICLES from config]
#   -B FILE   overlay the beam backgrounds of this background config
#             (configs/allbg_*.env): one gun particle per 2 us frame
#   -M NAME   overlay merger: timeframebuilder or hepmcmerger  [timeframebuilder]
#   -o DIR    output base                                         [./out]   
#   -m MB     request_memory                                     [6000]
#   -F        keep the FULL (edm4hep) files too
#   -H        overlay: keep the merged HepMC files too
#   -d        dry run: write the run directories and .sub files, do not submit
#
# Plain gun: each particle gets its own run directory, laid out like
# production's EVGEN/SINGLE tree: OUT/SINGLE/<particle>/<energy>/<min>to<max>deg/.
# The stem is <particle>_<energy>_<min>to<max>deg. npsim runs the template
# steering on DETECTOR_CONFIG_EBEAMxPBEAM (5x41 for singles).
#
# Overlay (-B): OUT/SINGLE_BG/<bg sample>/<merger>/<particle>/<energy>/<variant>/.
# Each frame (event) is one gun particle, the merger's signal at frequency 0,
# plus every source of the background config at its real rate. The geometry
# is the background config's beams (its backgrounds are beam-specific), not
# the gun config's. Background-only chunks reserve one source as the merger's
# "signal"; overlay chunks don't, so all of them are backgrounds.
# SignalBackgroundMerger takes at most four, so with five sources only
# timeframebuilder runs. It uses the patched build in tfb-patched/build
# (its memory fix, README) unless MERGER_PATH is set.
#
# A run directory holds run.env, the steering (or backgrounds.json), the
# .sub file and the Condor logs; RECO/ and LOG/ fill as chunks finish. A
# chunk whose RECO file exists exits at once, so resubmitting is safe. A run
# directory refuses to be extended with a different configuration.
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
TOP=$(dirname "${HERE}")

CONFIG="" NJOBS="" FIRST=0 OUT_BASE=${TOP}/out MEM=6000 KEEP_FULL=0 KEEP_MERGED=0 DRY=0
EPC="" PARTS="" BGCONFIG="" MERGER=timeframebuilder
while getopts "c:n:s:e:p:B:M:o:m:FHd" opt; do
  case $opt in
    c) CONFIG=$OPTARG ;; n) NJOBS=$OPTARG ;; s) FIRST=$OPTARG ;; e) EPC=$OPTARG ;;
    p) PARTS=$OPTARG ;; B) BGCONFIG=$OPTARG ;; M) MERGER=$OPTARG ;;
    o) OUT_BASE=$OPTARG ;; m) MEM=$OPTARG ;; F) KEEP_FULL=1 ;; H) KEEP_MERGED=1 ;; d) DRY=1 ;;
    *) sed -n '2,39p' "$0"; exit 2 ;;
  esac
done
[ -n "${CONFIG}" ] || { sed -n '2,39p' "$0"; exit 2; }
CONFIG=$(realpath "${CONFIG}")
source "${CONFIG}"
[ "${MODE:-}" = gun ] || { echo "${CONFIG} does not set MODE=gun"; exit 2; }
PARTS=${PARTS:-${GUN_PARTICLES}}
[ -d "${CONTAINER}" ] || [ -f "${CONTAINER}" ] || { echo "no container ${CONTAINER}"; exit 1; }
ENERGY_LABEL=${GUN_ENERGY//\*/}           # 20*GeV -> 20GeV
VARIANT=${GUN_THETA_MIN}to${GUN_THETA_MAX}deg

GUN_OVERLAY=0
if [ -n "${BGCONFIG}" ]; then
  GUN_OVERLAY=1
  BGCONFIG=$(realpath "${BGCONFIG}")
  # The background config's values, read in a subshell so they don't overwrite the gun's.
  bg() { (cd "${TOP}"; source "${BGCONFIG}"; v=${!1:-}; [ "$1" = SOURCES_JSON ] && [ -n "$v" ] && v=$(realpath "$v"); printf '%s' "$v"); }
  BG_SAMPLE=$(bg SAMPLE); SOURCES=$(bg SOURCES_JSON)
  [ -f "${SOURCES}" ] || { echo "no sources file ${SOURCES} (from ${BGCONFIG})"; exit 1; }
  EBEAM=$(bg EBEAM) PBEAM=$(bg PBEAM) DETECTOR_CONFIG=$(bg DETECTOR_CONFIG)
  INTEGRATION_WINDOW=$(bg INTEGRATION_WINDOW)
  NBG=$(jq length "${SOURCES}")
  case "${MERGER}" in
    timeframebuilder)
      MERGER_CONTAINER=$(bg TFB_CONTAINER)
      MERGER_PATH=${MERGER_PATH:-$(bg MERGER_PATH)}
      if [ -z "${MERGER_PATH}" ] && [ -x "${TOP}/tfb-patched/build/timeframe_builder" ]; then
        MERGER_PATH=$(realpath "${TOP}/tfb-patched/build")
      fi ;;
    hepmcmerger)
      [ "${NBG}" -le 4 ] || { echo "SignalBackgroundMerger takes at most 4 backgrounds; ${BGCONFIG} has ${NBG} sources. Use -M timeframebuilder."; exit 1; }
      HB=$(bg HEPMCMERGER_CONTAINER); MERGER_CONTAINER=${HB:-${CONTAINER}}; MERGER_PATH=${MERGER_PATH:-} ;;
    *) echo "unknown merger ${MERGER}"; exit 2 ;;
  esac
  [ -n "${MERGER_CONTAINER}" ] || { echo "${BGCONFIG} names no image for ${MERGER}"; exit 1; }
  EVENTS_PER_CHUNK=${EPC:-${OVERLAY_EVENTS_PER_CHUNK:-100}}
else
  EVENTS_PER_CHUNK=${EPC:-${EVENTS_PER_CHUNK}}
fi
[ -n "${NJOBS}" ] || NJOBS=$(( (GUN_EVENTS + EVENTS_PER_CHUNK - 1) / EVENTS_PER_CHUNK ))
LAST=$((FIRST + NJOBS - 1))
COMPACT=/opt/detector/epic-${DETECTOR_VERSION}/share/epic/${DETECTOR_CONFIG}_${EBEAM}x${PBEAM}.xml
apptainer exec "${CONTAINER}" test -f "${COMPACT}" || { echo "no geometry ${COMPACT} in ${CONTAINER}"; exit 1; }

# Run-directory identity: a directory is one configuration.
check_same() {
  local dir=$1; shift
  [ -f "${dir}/run.env" ] || return 0
  for k in "$@"; do
    old=$(sed -n "s/^${k}=//p" "${dir}/run.env")
    [ "${old}" = "${!k:-}" ] || { echo "${dir} was set up with ${k}=${old}, not ${!k:-}; use another -o"; exit 1; }
  done
}

for P in ${PARTS}; do
  STEM=${P}_${ENERGY_LABEL}_${VARIANT}
  STEER_NEW=$(bash "${HERE}/steering.sh" "${P}" "${GUN_ENERGY}" "${GUN_THETA_MIN}" "${GUN_THETA_MAX}")
  if [ "${GUN_OVERLAY}" = 1 ]; then
    OUT_DIR=$(realpath -m "${OUT_BASE}/SINGLE_BG/${BG_SAMPLE}/${MERGER}/${P}/${ENERGY_LABEL}/${VARIANT}")
    mkdir -p "${OUT_DIR}/condor"
    GUN_PARTICLE=${P} GUN_ENERGY_GEV=$(awk "BEGIN{print ${GUN_ENERGY//GeV/1}}")
    FRAMES=${EVENTS_PER_CHUNK}
    check_same "${OUT_DIR}" FRAMES CONTAINER MERGER MERGER_CONTAINER MERGER_PATH SOURCES GUN_ENERGY_GEV GUN_THETA_MIN GUN_THETA_MAX
    cp "${SOURCES}" "${OUT_DIR}/backgrounds.json"
    printf '%s\n' "${STEER_NEW}" > "${OUT_DIR}/${STEM}.steer"   # for reference: the template these kinematics follow
    cat > "${OUT_DIR}/run.env" <<ENV
# Written by gun/submit_gun.sh -B $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${CONFIG} + ${BGCONFIG}
GUN_OVERLAY=1
SAMPLE=${STEM}
BG_SAMPLE=${BG_SAMPLE}
SOURCES=${SOURCES}
CONTAINER=${CONTAINER}
MERGER=${MERGER}
MERGER_CONTAINER=${MERGER_CONTAINER}
MERGER_PATH=${MERGER_PATH}
DETECTOR_VERSION=${DETECTOR_VERSION}
DETECTOR_CONFIG=${DETECTOR_CONFIG}
EBEAM=${EBEAM}
PBEAM=${PBEAM}
INTEGRATION_WINDOW=${INTEGRATION_WINDOW}
FRAMES=${FRAMES}
GUN_PARTICLE=${GUN_PARTICLE}
GUN_ENERGY_GEV=${GUN_ENERGY_GEV}
GUN_THETA_MIN=${GUN_THETA_MIN}
GUN_THETA_MAX=${GUN_THETA_MAX}
SIGNAL_FILE=
SIGNAL_FREQ=0
SIGNAL_STATUS=0
SIGNAL_BLOCK=0
OUT_DIR=${OUT_DIR}
KEEP_FULL=${KEEP_FULL}
KEEP_MERGED=${KEEP_MERGED}
MERGE_ONLY=0
ENV
  else
    OUT_DIR=$(realpath -m "${OUT_BASE}/SINGLE/${P}/${ENERGY_LABEL}/${VARIANT}")
    mkdir -p "${OUT_DIR}/condor"
    check_same "${OUT_DIR}" EVENTS_PER_CHUNK CONTAINER DETECTOR_VERSION DETECTOR_CONFIG EBEAM PBEAM
    if [ -f "${OUT_DIR}/${STEM}.steer" ] && [ "$(cat "${OUT_DIR}/${STEM}.steer")" != "${STEER_NEW}" ]; then
      echo "${OUT_DIR} has a different steering; use another -o"; exit 1
    fi
    printf '%s\n' "${STEER_NEW}" > "${OUT_DIR}/${STEM}.steer"
    cat > "${OUT_DIR}/run.env" <<ENV
# Written by gun/submit_gun.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${CONFIG}
SAMPLE=${STEM}
CONTAINER=${CONTAINER}
DETECTOR_VERSION=${DETECTOR_VERSION}
DETECTOR_CONFIG=${DETECTOR_CONFIG}
EBEAM=${EBEAM}
PBEAM=${PBEAM}
EVENTS_PER_CHUNK=${EVENTS_PER_CHUNK}
OUT_DIR=${OUT_DIR}
KEEP_FULL=${KEEP_FULL}
ENV
  fi
  SUB=${OUT_DIR}/condor/${STEM}.${FIRST}-${LAST}.sub
  cat > "${SUB}" <<SUBF
universe         = vanilla
executable       = ${HERE}/gun_job.sh
arguments        = \$(chunk) ${OUT_DIR}
accounting_group = group_eic
request_memory   = ${MEM} MB
request_cpus     = 1
request_disk     = 20 GB
getenv           = False
output           = ${OUT_DIR}/condor/\$(chunk).out
error            = ${OUT_DIR}/condor/\$(chunk).err
log              = ${OUT_DIR}/condor/${STEM}.log
batch_name       = ${STEM}${GUN_OVERLAY:+$([ "${GUN_OVERLAY}" = 1 ] && echo ".bg-${MERGER}")}
queue chunk from seq ${FIRST} ${LAST} |
SUBF
  HASH=$(printf '%s' "${STEM}" | sha256sum | cut -c1-7)
  echo "gun      ${STEM}: ${GUN_ENERGY} ${P}, cos(theta) ${GUN_THETA_MIN}-${GUN_THETA_MAX} deg"
  echo "chunks   ${FIRST}-${LAST} x ${EVENTS_PER_CHUNK} events ($((NJOBS * EVENTS_PER_CHUNK)) events), seeds $(( (16#${HASH} * 10000 + FIRST + 1) % 2147483647 ))..$(( (16#${HASH} * 10000 + LAST + 1) % 2147483647 ))"
  if [ "${GUN_OVERLAY}" = 1 ]; then
    echo "overlay  ${BG_SAMPLE} via ${MERGER} in $(basename "${MERGER_CONTAINER}")${MERGER_PATH:+ (merger from ${MERGER_PATH})}"
    jq -r '.[] | "bg       \(.file | split("/")[-1]) at \(.freq) kHz, status \(.status)"' "${OUT_DIR}/backgrounds.json"
  fi
  echo "geometry ${DETECTOR_CONFIG}_${EBEAM}x${PBEAM}.xml, $(basename "${CONTAINER}")"
  echo "output   ${OUT_DIR}"
  echo "sub      ${SUB}"
  if [ "${DRY}" = 1 ]; then echo "dry run: not submitted"; else condor_submit "${SUB}"; fi
done
