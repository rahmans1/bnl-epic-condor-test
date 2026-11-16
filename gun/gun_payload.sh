#!/bin/bash
# Particle-gun chunk, inside CONTAINER: npsim runs the gun from the steering,
# then eicrecon.
#
#   gun/gun_payload.sh <chunk> <run_dir> <work_dir>
#
# This follows the epicprod payload's gun branch (swf-epicprod
# swf_epicprod/payload/run.sh, commit 5fddcb9). The seed mixes the stem's
# SHA-256 with the chunk, so each stem and each chunk gets its own random
# stream. The geometry is DETECTOR_CONFIG_EBEAMxPBEAM; production singles
# use 5x41. npsim gets the common flags plus --runType run --enableGun
# --steeringFile, and eicrecon gets the same flags as in production.
set -Euo pipefail
CHUNK=${1:?chunk index}
RUN_DIR=${2:?run directory}
WORK=${3:?work directory}
source "${RUN_DIR}/run.env"

TASKNAME=${SAMPLE}.$(printf '%04d' "${CHUNK}")
# run.sh: GUN_STEM_HASH is the stem's first 7 hex digits; the seed is
# (hash * 10000 + chunk + 1) mod (2^31 - 1).
GUN_STEM_HASH=$(printf '%s' "${SAMPLE}" | sha256sum | cut -c1-7)
SEED=$(( (16#${GUN_STEM_HASH} * 10000 + 10#${CHUNK} + 1) % 2147483647 ))
[ ${SEED} -gt 0 ] || SEED=1
LOG_TEMP=${WORK}/LOG; FULL_TEMP=${WORK}/FULL; RECO_TEMP=${WORK}/RECO
mkdir -p "${LOG_TEMP}" "${FULL_TEMP}" "${RECO_TEMP}"
STAGES_LOG=${LOG_TEMP}/${TASKNAME}.stages.log
cd "${WORK}"

CURRENT_STAGE=""
stage() {
  CURRENT_STAGE=$1
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1 $2${3:+ $3}" | tee -a "${STAGES_LOG}"
}
trap 's=$?; echo "$0: error on line $LINENO: $BASH_COMMAND"; [ -n "$CURRENT_STAGE" ] && stage "$CURRENT_STAGE" fail "line $LINENO exit $s"; exit $s' ERR
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

DETECTOR_CONFIG_REQUESTED=${DETECTOR_CONFIG}
set --
source /opt/detector/epic-${DETECTOR_VERSION}/bin/thisepic.sh
export DETECTOR_CONFIG=${DETECTOR_CONFIG_REQUESTED}
export DETECTOR_COMPACT=${DETECTOR_PATH}/${DETECTOR_CONFIG}_${EBEAM}x${PBEAM}.xml
stage geometry start
[ -f "${DETECTOR_COMPACT}" ] || { stage geometry fail "${DETECTOR_COMPACT} does not exist"; exit 83; }
stage geometry ok "$(basename "${DETECTOR_COMPACT}"), the particle gun's field configuration"
cp "${RUN_DIR}/${SAMPLE}.steer" "${WORK}/${SAMPLE}.steer"

stage simulation start "${EVENTS_PER_CHUNK} events, seed ${SEED}"
{
  date
  eic-info 2>/dev/null | head -5 || true
  cat "${WORK}/${SAMPLE}.steer"
  monitor npsim npsim \
    --random.seed "${SEED}" \
    --random.enableEventSeed \
    --printLevel WARNING \
    --filter.tracker 'edep0' \
    --numberOfEvents "${EVENTS_PER_CHUNK}" \
    --compactFile "${DETECTOR_COMPACT}" \
    --outputFile "${FULL_TEMP}/${TASKNAME}.edm4hep.root" \
    --runType run \
    --enableGun \
    --steeringFile "${WORK}/${SAMPLE}.steer"
  ls -al "${FULL_TEMP}/${TASKNAME}.edm4hep.root"
} 2>&1 | tee "${LOG_TEMP}/${TASKNAME}.npsim.log" | tail -n 200
[ -s "${FULL_TEMP}/${TASKNAME}.edm4hep.root" ] || { stage simulation fail "no FULL file"; exit 84; }
stage simulation ok

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
[ -s "${RECO_TEMP}/${TASKNAME}.eicrecon.edm4eic.root" ] || { stage reconstruction fail "no RECO file"; exit 85; }
stage reconstruction ok
