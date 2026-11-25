#!/usr/bin/env python3
"""Print what a RECO (or FULL) file holds, event by event: the gun particles
(generator status 1) with PDG, theta, |p| and time, plus counts by generator
status (2001 SYNRAD, 3001 brems, 4001 Coulomb, 5001 Touschek, 6001 proton
beam-gas, 4 beams). Run it inside the image, e.g.

  apptainer exec --cleanenv -B /gpfs02,/gpfs/mnt/gpfs02 \\
    /cvmfs/singularity.opensciencegrid.org/eicweb/eic_xl:26.11.0-stable \\
    python3 tools/check_reco.py out/SINGLE/pi+/20GeV/1to4deg/RECO/<file>.root [max_events]
"""
import collections
import sys

import numpy as np
import uproot

path = sys.argv[1]
nmax = int(sys.argv[2]) if len(sys.argv) > 2 else 10
t = uproot.open(path)['events']
br = ['MCParticles.PDG', 'MCParticles.generatorStatus', 'MCParticles.time'] + \
     [f'MCParticles.momentum.{c}' for c in 'xyz']
a = t.arrays(br, entry_stop=nmax)
print(f'{path}: {t.num_entries} events (showing {min(nmax, t.num_entries)})')
for i in range(len(a)):
    st = np.asarray(a['MCParticles.generatorStatus'][i])
    g = st == 1
    px, py, pz = (np.asarray(a[f'MCParticles.momentum.{c}'][i][g]) for c in 'xyz')
    p = np.sqrt(px ** 2 + py ** 2 + pz ** 2)
    theta = np.degrees(np.arccos(np.divide(pz, p, out=np.zeros_like(p), where=p > 0)))
    counts = dict(sorted(collections.Counter(st[st > 0].tolist()).items()))
    print(f'{i:4d} gun pdg {np.asarray(a["MCParticles.PDG"][i][g]).tolist()} '
          f'theta {np.round(theta.astype(float), 3).tolist()} |p| {np.round(p.astype(float), 3).tolist()} '
          f't {np.round(np.asarray(a["MCParticles.time"][i][g], dtype=float), 1).tolist()} | status {counts}')
