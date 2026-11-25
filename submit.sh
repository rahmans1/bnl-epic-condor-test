#!/bin/bash
# Submit background-only mixed runs to BNL SDCC HTCondor. A config with
# MODE=gun runs particle-gun singles instead (gun/submit_gun.sh), and one
# with MODE=file a generator HepMC3 file, plain or with -B background
# overlay (file/submit_file.sh).
#
#   ./submit.sh -c configs/allbg_10x275_gold10um.env -n 100 -f 100 [options]
#
#   -c FILE   sample configuration (configs/*.env)
#   -n N      number of chunks (Condor jobs)                     [required]
#   -f N      frames (2 us time slices) per chunk                [100]
#   -s N      first chunk index (to extend a run)                [0]
#   -M NAME   merger: hepmcmerger or timeframebuilder            [hepmcmerger]
#   -C REL    eic_xl release for every step, e.g. 26.10.0  [the config's CONTAINER]
#   -o DIR    output base; the run goes to DIR/<SAMPLE>/<MERGER> [./out]
#   -m MB     initial request_memory                             [6000]
#   -R MB     memory cap for automatic retries (x2 per OOM)      [12000]
#   -F        keep the FULL (edm4hep) files too
#   -H        keep the merged HepMC files too
#   -X        merge-only benchmark: merge, then bench/extract.py's summary to
#             BENCH/ instead of simulation (bench/README.md); the run goes to
#             DIR/<SAMPLE>/bench-<MERGER>
#   -d        dry run: write the run directory and .sub, do not submit
#
# Every step (merge, simulation, reconstruction) runs in the config's one
# CONTAINER, the latest eic_xl release. Both merger modes use the same seeds,
# so the modes compare chunk for chunk.
#
# MERGER_PATH, from the config or the environment, puts a directory first on
# PATH for the merge step (a locally built merger, e.g. tfb-patched/build).
#
# The run directory (OUT/<SAMPLE>/<MERGER>) holds run.env, backgrounds.json, the .sub
# file and the Condor logs; RECO/, LOG/ (and FULL/, HEPMC/) fill as chunks end.
# A chunk whose RECO file exists exits at once, so resubmitting is safe.
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")

# A config with MODE=gun is a particle-gun run: gun/submit_gun.sh takes it,
# with its own options (gun/submit_gun.sh, header).
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = -c ]; then j=$((i + 1))
    if [ -f "${!j:-}" ] && grep -q '^MODE=gun' "${!j}"; then exec "${HERE}/gun/submit_gun.sh" "$@"; fi
    if [ -f "${!j:-}" ] && grep -q '^MODE=file' "${!j}"; then exec "${HERE}/file/submit_file.sh" "$@"; fi
  fi
done

CONFIG="" NJOBS="" FRAMES=100 FIRST=0 OUT_BASE=${HERE}/out MEM=6000 MEM_MAX=12000
KEEP_FULL=0 KEEP_MERGED=0 DRY=0 MERGER=hepmcmerger MERGE_ONLY=0 RELEASE="" OUT_SET=0
while getopts "c:n:f:s:M:C:o:m:R:FHXd" opt; do
  case $opt in
    c) CONFIG=$OPTARG ;; n) NJOBS=$OPTARG ;; f) FRAMES=$OPTARG ;;
    s) FIRST=$OPTARG ;; M) MERGER=$OPTARG ;; C) RELEASE=$OPTARG ;; o) OUT_BASE=$OPTARG; OUT_SET=1 ;; m) MEM=$OPTARG ;; R) MEM_MAX=$OPTARG ;;
    F) KEEP_FULL=1 ;; H) KEEP_MERGED=1 ;; X) MERGE_ONLY=1 ;; d) DRY=1 ;;
    *) sed -n '2,34p' "$0"; exit 2 ;;
  esac
done
[ -n "${CONFIG}" ] && [ -n "${NJOBS}" ] || { sed -n '2,34p' "$0"; exit 2; }
CONFIG=$(realpath "${CONFIG}")
source "${CONFIG}"
cd "${HERE}"
# -C RELEASE: run every step in that eic_xl release instead of the config's
# (tools/releases.sh lists them); the detector release follows it. Without
# -o such a run goes under out/release-<RELEASE>/, apart from the default's.
if [ -n "${RELEASE}" ]; then
  CONTAINER=/cvmfs/singularity.opensciencegrid.org/eicweb/eic_xl:${RELEASE}-stable
  DETECTOR_VERSION=${RELEASE}
  [ -d "${CONTAINER}" ] || { echo "no eic_xl release ${RELEASE} on CVMFS; tools/releases.sh lists the ones there"; exit 1; }
  [ "${OUT_SET}" = 1 ] || OUT_BASE=${OUT_BASE}/release-${RELEASE}
fi

SOURCES=$(realpath "${SOURCES_JSON}")
[ -f "${SOURCES}" ] || { echo "no sources file ${SOURCES}"; exit 1; }
# One image for every step: the merger runs in CONTAINER too.
MERGER_CONTAINER=${CONTAINER}
# TimeFrameBuilder is only in eic_xl 26.08.0 and later.
if [ "${MERGER}" = timeframebuilder ] && [ -z "${MERGER_PATH:-}" ] && ! [ -L "${CONTAINER}/opt/local/bin/timeframe_builder" ] && ! [ -e "${CONTAINER}/opt/local/bin/timeframe_builder" ]; then
  echo "$(basename "${CONTAINER}") has no timeframe_builder; pick a release that does (tools/releases.sh) or use hepmcmerger"; exit 1
fi
case "${MERGER}" in
  hepmcmerger|timeframebuilder) ;;
  *) echo "unknown merger ${MERGER} (hepmcmerger or timeframebuilder)"; exit 2 ;;
esac
[ -f "mergers/${MERGER}.sh" ] || { echo "no adapter mergers/${MERGER}.sh"; exit 1; }
for img in "${CONTAINER}" "${MERGER_CONTAINER}"; do
  [ -d "${img}" ] || [ -f "${img}" ] || { echo "no container ${img}"; exit 1; }
done

# Split the sources: the chosen row is the signal, the rest are backgrounds.
SIG=$(jq -c --argjson st "${SIGNAL_ROW_STATUS}" '[.[] | select(.status == $st)]' "${SOURCES}")
[ "$(jq length <<<"${SIG}")" = 1 ] || { echo "need exactly one source with status ${SIGNAL_ROW_STATUS}"; exit 1; }
SIGNAL_FILE=$(jq -r '.[0].file' <<<"${SIG}")
SIGNAL_FREQ=$(jq -r '.[0].freq' <<<"${SIG}")
SIGNAL_STATUS=$(jq -r '.[0].status' <<<"${SIG}")
awk "BEGIN{exit !(${SIGNAL_FREQ} > 0)}" || { echo "signal row must have freq > 0 (it is a background)"; exit 1; }

# Signal events per chunk: mean = freq * window * frames, plus 6 sigma and a
# floor, so chunks never share a signal event.
SIGNAL_BLOCK=$(awk "BEGIN {m=${SIGNAL_FREQ}*${INTEGRATION_WINDOW}*1e-6*${FRAMES}; b=m+6*sqrt(m)+10; printf \"%d\", b+1}")
LAST=$((FIRST + NJOBS - 1))
NEED=$(( (LAST + 1) * SIGNAL_BLOCK ))
if [ "${NEED}" -gt "${SIGNAL_NEVENTS}" ]; then
  echo "chunks ${FIRST}-${LAST} need signal events up to ${NEED}, the file has ${SIGNAL_NEVENTS}"; exit 1
fi

RUN_NAME=${MERGER}
[ "${MERGE_ONLY}" = 1 ] && RUN_NAME=bench-${MERGER}
OUT_DIR=$(realpath -m "${OUT_BASE}/${SAMPLE}/${RUN_NAME}")
mkdir -p "${OUT_DIR}/condor"
# A run directory is one configuration: refuse to extend it with another.
if [ -f "${OUT_DIR}/run.env" ]; then
  for k in FRAMES SIGNAL_BLOCK CONTAINER SOURCES MERGER MERGER_CONTAINER MERGE_ONLY MERGER_PATH; do
    old=$(sed -n "s/^${k}=//p" "${OUT_DIR}/run.env" | tr -d "'\"")
    new=${!k:-}
    [ "${old}" = "${new}" ] || { echo "${OUT_DIR} was set up with ${k}=${old}, not ${new}; use another -o"; exit 1; }
  done
fi
jq --argjson st "${SIGNAL_ROW_STATUS}" '[.[] | select(.status != $st)]' "${SOURCES}" > "${OUT_DIR}/backgrounds.json"
cat > "${OUT_DIR}/run.env" <<EOF
# Written by submit.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${CONFIG}
SAMPLE=${SAMPLE}
SOURCES=${SOURCES}
CONTAINER=${CONTAINER}
MERGER=${MERGER}
MERGER_CONTAINER=${MERGER_CONTAINER}
DETECTOR_VERSION=${DETECTOR_VERSION}
DETECTOR_CONFIG=${DETECTOR_CONFIG}
EBEAM=${EBEAM}
PBEAM=${PBEAM}
INTEGRATION_WINDOW=${INTEGRATION_WINDOW}
FRAMES=${FRAMES}
SIGNAL_FILE=${SIGNAL_FILE}
SIGNAL_FREQ=${SIGNAL_FREQ}
SIGNAL_STATUS=${SIGNAL_STATUS}
SIGNAL_BLOCK=${SIGNAL_BLOCK}
OUT_DIR=${OUT_DIR}
KEEP_FULL=${KEEP_FULL}
KEEP_MERGED=${KEEP_MERGED}
MERGE_ONLY=${MERGE_ONLY}
MERGER_PATH=${MERGER_PATH:-}
EOF

SUB=${OUT_DIR}/condor/${SAMPLE}.${FIRST}-${LAST}.sub
cat > "${SUB}" <<EOF
universe         = vanilla
executable       = ${HERE}/job.sh
arguments        = \$(chunk) ${OUT_DIR}
accounting_group = group_eic
request_memory   = ${MEM} MB
# Memory escalation: a job killed for exceeding its memory goes back to the
# queue with twice the request, up to ${MEM_MAX} MB (HTCondor
# retry_request_memory; SDCC enforces hard cgroup limits). After 4 starts a
# job is held instead of looping.
retry_request_memory = min({RequestMemory * 2, ${MEM_MAX}})
periodic_hold    = (NumJobStarts >= 4) && (JobStatus == 1)
periodic_hold_reason = "held after 4 starts: memory retries up to ${MEM_MAX} MB exhausted, or repeated eviction"
request_cpus     = 1
request_disk     = 20 GB
getenv           = False
output           = ${OUT_DIR}/condor/\$(chunk).out
error            = ${OUT_DIR}/condor/\$(chunk).err
log              = ${OUT_DIR}/condor/${SAMPLE}.log
batch_name       = ${SAMPLE}.${RUN_NAME}
queue chunk from seq ${FIRST} ${LAST} |
EOF

echo "sample   ${SAMPLE}"
echo "merger   ${MERGER} in $(basename "${MERGER_CONTAINER}"); sim/reco in $(basename "${CONTAINER}")"
echo "chunks   ${FIRST}-${LAST} x ${FRAMES} frames ($((NJOBS * FRAMES)) frames, $(awk "BEGIN{print ${NJOBS}*${FRAMES}*${INTEGRATION_WINDOW}*1e-6}") ms of beam)"
echo "signal   $(basename "${SIGNAL_FILE}") at ${SIGNAL_FREQ} kHz, status ${SIGNAL_STATUS}, ${SIGNAL_BLOCK} events per chunk"
jq -r '.[] | "bg       \(.file | split("/")[-1]) at \(.freq) kHz, status \(.status)"' "${OUT_DIR}/backgrounds.json"
[ -n "${MERGER_PATH:-}" ] && echo "path     ${MERGER_PATH} first on PATH for the merge"
echo "output   ${OUT_DIR}"
echo "sub      ${SUB}"
if [ "${DRY}" = 1 ]; then
  echo "dry run: not submitted"
else
  condor_submit "${SUB}"
fi
