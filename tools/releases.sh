#!/bin/bash
# eic_xl releases available on CVMFS, newest last, with what each one has:
# its detector release, and whether the mergers are in the image.
#
#   tools/releases.sh [N]        # the newest N stable releases [8]; "all" for every one
#
# Pick one for a run with -C on any submit command:
#   ./submit.sh -c configs/<config>.env -C 26.10.0 ...
# Without -C a run uses the config's CONTAINER (the latest release).
set -uo pipefail
BASE=/cvmfs/singularity.opensciencegrid.org/eicweb
N=${1:-8}
tags=$(ls "${BASE}" 2>/dev/null | sed -n 's/^eic_xl:\([0-9]*\.[0-9]*\.[0-9]*\)-stable$/\1/p' | sort -V)
[ -n "${tags}" ] || { echo "no eic_xl releases under ${BASE} (is CVMFS mounted?)"; exit 1; }
[ "${N}" = all ] || tags=$(tail -n "${N}" <<<"${tags}")
latest=$(tail -n 1 <<<"${tags}")
printf '%-10s %-10s %-12s %-16s %s\n' release detector hepmcmerger timeframebuilder note
for v in ${tags}; do
  img=${BASE}/eic_xl:${v}-stable
  det=no; [ -d "${img}/opt/detector/epic-${v}" ] && det=${v}
  hm=no;  { [ -e "${img}/opt/local/bin/SignalBackgroundMerger" ] || [ -L "${img}/opt/local/bin/SignalBackgroundMerger" ]; } && hm=yes
  tfb=no; { [ -e "${img}/opt/local/bin/timeframe_builder" ] || [ -L "${img}/opt/local/bin/timeframe_builder" ]; } && tfb=yes
  note=""; [ "${v}" = "${latest}" ] && note="latest (the configs' default)"
  printf '%-10s %-10s %-12s %-16s %s\n' "${v}" "${det}" "${hm}" "${tfb}" "${note}"
done
