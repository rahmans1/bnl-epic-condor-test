#!/bin/bash
# Status of every run directory under an output base: RECO files written vs
# chunks submitted, Condor jobs by state, and the last failed stage of each
# failed chunk.
#
#   tools/status.sh [OUT_BASE]        # default: ./out
set -uo pipefail
HERE=$(dirname "$(realpath "$0")")
BASE=$(realpath -m "${1:-${HERE}/../out}")
[ -d "${BASE}" ] || { echo "no output base ${BASE}"; exit 1; }
printf '%-70s %8s %8s  %s\n' "run directory" "RECO" "chunks" "condor (idle/run/held)"
find "${BASE}" -name run.env -printf '%h\n' | sort | while read -r d; do
  reco=$(find "$d/RECO" -name '*.root' 2>/dev/null | wc -l)
  chunks=$(ls "$d"/condor/*.sub 2>/dev/null | sed -n 's/.*\.\([0-9]*\)-\([0-9]*\)\.sub$/\1 \2/p' | awk '{n+=$2-$1+1} END{print n+0}')
  log=$(ls "$d"/condor/*.log 2>/dev/null | head -1)
  q="-"
  if [ -n "${log}" ]; then
    ids=$(grep -o '^000 ([0-9]*\.' "$d"/condor/*.log 2>/dev/null | sed 's/.*(\([0-9]*\)\./\1/' | sort -u | tr '\n' ' ')
    if [ -n "${ids}" ]; then
      q=$(condor_q ${ids} -af JobStatus 2>/dev/null | awk '{c[$1]++} END{printf "%d/%d/%d", c[1]+0, c[2]+0, c[5]+0}')
    fi
  fi
  printf '%-70s %8s %8s  %s\n' "${d#${BASE}/}" "${reco}" "${chunks}" "${q}"
  # failed stages, from the stage logs inside each chunk's log tarball
  for t in "$d"/LOG/*.log.tar.gz; do
    [ -f "$t" ] || continue
    fail=$(tar -xzOf "$t" --wildcards '*.stages.log' 2>/dev/null | grep ' fail' | tail -1)
    if [ -n "${fail}" ]; then echo "    $(basename "$t" .log.tar.gz): ${fail}"; fi
  done
done
exit 0
