#!/bin/bash
# Submit a generator HepMC3 file (EVGEN) to BNL SDCC HTCondor, plain or with
# the beam backgrounds overlaid. submit.sh calls this script when the config
# sets MODE=file.
#
#   ./submit.sh -c configs/beagle_eAg_9x115_q2_1to10.env [options]
#
#   -c FILE   file configuration (MODE=file; header of configs/beagle_*.env)
#   -n N      number of chunks (Condor jobs)          [SIGNAL_NEVENTS / events per chunk]
#   -s N      first chunk index (to extend a run)                [0]
#   -e N      events per chunk                         [EVENTS_PER_CHUNK from config]
#   -B FILE   overlay the beam backgrounds of this background config
#             (configs/allbg_*.env): one signal event per 2 us frame
#   -M NAME   overlay merger: hepmcmerger or timeframebuilder    [hepmcmerger]
#   -C REL    eic_xl release for every step, e.g. 26.10.0  [the config's CONTAINER]
#   -o DIR    output base                                         [./out]
#   -m MB     initial request_memory                             [6000]
#   -R MB     memory cap for automatic retries (x2 per OOM)      [12000]
#   -F        keep the FULL (edm4hep) files too
#   -H        overlay: keep the merged HepMC files too
#   -d        dry run: write the run directory and .sub, do not submit
#
# As run.sh with an EVGEN input: chunk c reads events c*N .. c*N+N-1 of the
# file (npsim --skipNEvents in plain runs; the merger's signal skip in
# overlays), with seed c+1. Overlay frames carry exactly one signal event
# (signal frequency 0) plus every background source at its real rate.
#
# Plain:   OUT/FILE/<SAMPLE>/plain/
# Overlay: OUT/FILE_BG/<bg sample>/<merger>/<SAMPLE>/
# The geometry is DETECTOR_CONFIG_<DETECTOR_BEAMS>.xml (DETECTOR_BEAMS
# defaults to EBEAMxPBEAM, as run.sh). An overlay's background config
# should have the same EBEAM/PBEAM (its sources are beam-specific); another
# energy's set runs for testing, with a warning, recorded as BG_BEAMS.
#
# The run directory holds run.env, backgrounds.json ([] when plain), the
# .sub file and the Condor logs; RECO/ and LOG/ fill as chunks finish. A
# chunk whose RECO file exists exits at once, so resubmitting is safe. A run
# directory refuses to be extended with a different configuration.
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
TOP=$(dirname "${HERE}")

CONFIG="" NJOBS="" FIRST=0 OUT_BASE=${TOP}/out MEM=6000 MEM_MAX=12000 KEEP_FULL=0 KEEP_MERGED=0 DRY=0
EPC="" BGCONFIG="" MERGER="" RELEASE="" OUT_SET=0
while getopts "c:n:s:e:B:M:C:o:m:R:FHd" opt; do
  case $opt in
    c) CONFIG=$OPTARG ;; n) NJOBS=$OPTARG ;; s) FIRST=$OPTARG ;; e) EPC=$OPTARG ;;
    B) BGCONFIG=$OPTARG ;; M) MERGER=$OPTARG ;;
    C) RELEASE=$OPTARG ;; o) OUT_BASE=$OPTARG; OUT_SET=1 ;; m) MEM=$OPTARG ;; R) MEM_MAX=$OPTARG ;; F) KEEP_FULL=1 ;; H) KEEP_MERGED=1 ;; d) DRY=1 ;;
    *) sed -n '2,38p' "$0"; exit 2 ;;
  esac
done
[ -n "${CONFIG}" ] || { sed -n '2,38p' "$0"; exit 2; }
CONFIG=$(realpath "${CONFIG}")
source "${CONFIG}"
[ "${MODE:-}" = file ] || { echo "${CONFIG} does not set MODE=file"; exit 2; }
# -C RELEASE: run every step in that eic_xl release instead of the config's
# (tools/releases.sh lists them); the detector release follows it. Without
# -o such a run goes under out/release-<RELEASE>/, apart from the default's.
if [ -n "${RELEASE}" ]; then
  CONTAINER=/cvmfs/singularity.opensciencegrid.org/eicweb/eic_xl:${RELEASE}-stable
  DETECTOR_VERSION=${RELEASE}
  [ -d "${CONTAINER}" ] || { echo "no eic_xl release ${RELEASE} on CVMFS; tools/releases.sh lists the ones there"; exit 1; }
  [ "${OUT_SET}" = 1 ] || OUT_BASE=${OUT_BASE}/release-${RELEASE}
fi
# A local path must exist; a root:// or https:// URL is streamed by the job.
case "${SIGNAL_FILE}" in
  root://*|https://*) ;;
  *) [ -f "${SIGNAL_FILE}" ] || { echo "no input file ${SIGNAL_FILE}"; exit 1; } ;;
esac
[ -d "${CONTAINER}" ] || [ -f "${CONTAINER}" ] || { echo "no container ${CONTAINER}"; exit 1; }
SIGNAL_STATUS=${SIGNAL_STATUS:-0}
DETECTOR_BEAMS=${DETECTOR_BEAMS:-${EBEAM}x${PBEAM}}
EVENTS_PER_CHUNK=${EPC:-${EVENTS_PER_CHUNK:-100}}
[ -n "${NJOBS}" ] || NJOBS=$(( (SIGNAL_NEVENTS + EVENTS_PER_CHUNK - 1) / EVENTS_PER_CHUNK ))
LAST=$((FIRST + NJOBS - 1))
NEED=$(( (LAST + 1) * EVENTS_PER_CHUNK ))
[ "${NEED}" -le "${SIGNAL_NEVENTS}" ] || { echo "chunks ${FIRST}-${LAST} need events up to ${NEED}; the file has ${SIGNAL_NEVENTS}"; exit 1; }
COMPACT=/opt/detector/epic-${DETECTOR_VERSION}/share/epic/${DETECTOR_CONFIG}_${DETECTOR_BEAMS}.xml
apptainer exec "${CONTAINER}" test -f "${COMPACT}" || { echo "no geometry ${COMPACT} in ${CONTAINER}"; exit 1; }

PLAIN=1 BG_BEAMS="" MERGER_CONTAINER="" MERGER_PATH=${MERGER_PATH:-} SOURCES="" BG_SAMPLE="" INTEGRATION_WINDOW=${INTEGRATION_WINDOW:-2000}
if [ -n "${BGCONFIG}" ]; then
  PLAIN=0
  BGCONFIG=$(realpath "${BGCONFIG}")
  # The background config's values, read in a subshell so they don't overwrite the sample's.
  bg() { (cd "${TOP}"; source "${BGCONFIG}"; v=${!1:-}; [ "$1" = SOURCES_JSON ] && [ -n "$v" ] && v=$(realpath "$v"); printf '%s' "$v"); }
  BG_SAMPLE=$(bg SAMPLE); SOURCES=$(bg SOURCES_JSON)
  [ -f "${SOURCES}" ] || { echo "no sources file ${SOURCES} (from ${BGCONFIG})"; exit 1; }
  # Backgrounds are beam-specific, but another energy's set is allowed for
  # testing: warned here and recorded as BG_BEAMS in run.env. The geometry
  # stays the sample's.
  BG_BEAMS=$(bg EBEAM)x$(bg PBEAM)
  if [ "${BG_BEAMS}" != "${EBEAM}x${PBEAM}" ]; then
    echo "WARNING  backgrounds are for ${BG_BEAMS}, the sample is ${EBEAM}x${PBEAM} (test only; geometry stays ${DETECTOR_BEAMS})"
  fi
  INTEGRATION_WINDOW=$(bg INTEGRATION_WINDOW)
  MERGER=${MERGER:-hepmcmerger}   # the production default (run.sh)
  case "${MERGER}" in
    hepmcmerger)
      ;;
    timeframebuilder)
      MERGER_PATH=${MERGER_PATH:-$(bg MERGER_PATH)}
      if [ -z "${MERGER_PATH}" ] && [ -z "${RELEASE}" ] && [ -x "${TOP}/tfb-patched/build/timeframe_builder" ]; then   # built for the default image only
        MERGER_PATH=$(realpath "${TOP}/tfb-patched/build")
      fi ;;
    *) echo "unknown merger ${MERGER} (hepmcmerger or timeframebuilder)"; exit 2 ;;
  esac
  # One image for every step: the merger runs in the sample's CONTAINER.
  MERGER_CONTAINER=${CONTAINER}
# TimeFrameBuilder is only in eic_xl 26.08.0 and later.
if [ "${MERGER}" = timeframebuilder ] && [ -z "${MERGER_PATH:-}" ] && ! [ -L "${CONTAINER}/opt/local/bin/timeframe_builder" ] && ! [ -e "${CONTAINER}/opt/local/bin/timeframe_builder" ]; then
  echo "$(basename "${CONTAINER}") has no timeframe_builder; pick a release that does (tools/releases.sh) or use hepmcmerger"; exit 1
fi
  [ -f "${TOP}/mergers/${MERGER}.sh" ] || { echo "no adapter mergers/${MERGER}.sh"; exit 1; }
  OUT_DIR=$(realpath -m "${OUT_BASE}/FILE_BG/${BG_SAMPLE}/${MERGER}/${SAMPLE}")
else
  OUT_DIR=$(realpath -m "${OUT_BASE}/FILE/${SAMPLE}/plain")
fi
mkdir -p "${OUT_DIR}/condor"

FRAMES=${EVENTS_PER_CHUNK}
if [ -f "${OUT_DIR}/run.env" ]; then
  for k in FRAMES SIGNAL_FILE CONTAINER DETECTOR_VERSION DETECTOR_CONFIG DETECTOR_BEAMS SOURCES MERGER MERGER_CONTAINER MERGER_PATH; do
    old=$(sed -n "s/^${k}=//p" "${OUT_DIR}/run.env")
    [ "${old}" = "${!k:-}" ] || { echo "${OUT_DIR} was set up with ${k}=${old}, not ${!k:-}; use another -o"; exit 1; }
  done
fi
if [ "${PLAIN}" = 1 ]; then echo '[]' > "${OUT_DIR}/backgrounds.json"; else cp "${SOURCES}" "${OUT_DIR}/backgrounds.json"; fi
cat > "${OUT_DIR}/run.env" <<ENV
# Written by file/submit_file.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${CONFIG}${BGCONFIG:+ + ${BGCONFIG}}
FILE_INPUT=1
PLAIN=${PLAIN}
SAMPLE=${SAMPLE}
BG_SAMPLE=${BG_SAMPLE}
BG_BEAMS=${BG_BEAMS}
SOURCES=${SOURCES}
CONTAINER=${CONTAINER}
MERGER=${MERGER}
MERGER_CONTAINER=${MERGER_CONTAINER}
MERGER_PATH=${MERGER_PATH}
DETECTOR_VERSION=${DETECTOR_VERSION}
DETECTOR_CONFIG=${DETECTOR_CONFIG}
DETECTOR_BEAMS=${DETECTOR_BEAMS}
EBEAM=${EBEAM}
PBEAM=${PBEAM}
INTEGRATION_WINDOW=${INTEGRATION_WINDOW}
FRAMES=${FRAMES}
SIGNAL_FILE=${SIGNAL_FILE}
SIGNAL_FREQ=0
SIGNAL_STATUS=${SIGNAL_STATUS}
SIGNAL_BLOCK=${FRAMES}
OUT_DIR=${OUT_DIR}
KEEP_FULL=${KEEP_FULL}
KEEP_MERGED=${KEEP_MERGED}
MERGE_ONLY=0
ENV

MERGER=${MERGER:-hepmcmerger}
MODE_LABEL=plain; [ "${PLAIN}" = 1 ] || MODE_LABEL=bg-${MERGER}
SUB=${OUT_DIR}/condor/${SAMPLE}.${FIRST}-${LAST}.sub
cat > "${SUB}" <<SUBF
universe         = vanilla
executable       = ${TOP}/job.sh
arguments        = \$(chunk) ${OUT_DIR}
accounting_group = group_eic
request_memory   = ${MEM} MB
request_cpus     = 1
request_disk     = 20 GB
getenv           = False
output           = ${OUT_DIR}/condor/\$(chunk).out
error            = ${OUT_DIR}/condor/\$(chunk).err
log              = ${OUT_DIR}/condor/${SAMPLE}.log
batch_name       = ${SAMPLE}.${MODE_LABEL}
# Memory escalation: a job killed for exceeding its memory goes back to the
# queue with twice the request, up to ${MEM_MAX} MB (HTCondor
# retry_request_memory; SDCC enforces hard cgroup limits). After 4 starts a
# job is held instead of looping.
retry_request_memory = min({RequestMemory * 2, ${MEM_MAX}})
periodic_hold    = (NumJobStarts >= 4) && (JobStatus == 1)
periodic_hold_reason = "held after 4 starts: memory retries up to ${MEM_MAX} MB exhausted, or repeated eviction"
queue chunk from seq ${FIRST} ${LAST} |
SUBF

echo "sample   ${SAMPLE}: $(basename "${SIGNAL_FILE}") (${SIGNAL_NEVENTS} events, status ${SIGNAL_STATUS})"
echo "chunks   ${FIRST}-${LAST} x ${EVENTS_PER_CHUNK} events (events $((FIRST * EVENTS_PER_CHUNK))-$((NEED - 1))), seeds $((FIRST + 1))..$((LAST + 1))"
if [ "${PLAIN}" = 1 ]; then
  echo "mode     plain (no backgrounds)"
else
  echo "overlay  ${BG_SAMPLE} via ${MERGER} in $(basename "${MERGER_CONTAINER}")${MERGER_PATH:+ (merger from ${MERGER_PATH})}"
  jq -r '.[] | "bg       \(.file | split("/")[-1]) at \(.freq) kHz, status \(.status)"' "${OUT_DIR}/backgrounds.json"
fi
echo "geometry ${DETECTOR_CONFIG}_${DETECTOR_BEAMS}.xml, $(basename "${CONTAINER}")"
echo "output   ${OUT_DIR}"
echo "sub      ${SUB}"
if [ "${DRY}" = 1 ]; then echo "dry run: not submitted"; else condor_submit "${SUB}"; fi
