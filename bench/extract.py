#!/usr/bin/env python3
"""Reduce one merged HepMC3 file (hepmc3_tree) to a compact, summable record
of what the merger placed, per source, for the merger comparison
(bench/README.md).

    extract.py <merged.hepmc3.tree.root> <out.npz> <status,status,...>

A source is known by its generatorStatus offset S (signal and backgrounds as
the merger was given them): its final-state particles have status S+1, its
beam particles S+4. Per source and per frame it records

  nev   source events placed: distinct end vertices of its beam particles
  nfs   final-state particles

and as fixed-binning histograms (summed later across jobs)

  tev   event time: the time of each placed event's primary vertex, ns
  tfs   final-state particle production-vertex time, ns
  p     final-state |p|, GeV (log bins)
  th    final-state polar angle, rad
  pid   final-state PDG codes and counts

and the order in which the merger read the source file:

  seq   a fingerprint (momentum bits and PDG code) of each final-state
        particle, in output order, for the first SEQ_MAX particles. The same
        input events read in the same order give the same sequence whatever
        times and multiplicities the merger drew.
"""
import json
import sys

import numpy as np
import uproot

C_MM_PER_NS = 299.792458
TBINS = np.linspace(-200.0, 2200.0, 121)        # 20 ns bins around a 2000 ns frame
PBINS = np.logspace(-9.0, 3.5, 136)             # 1 eV .. 3 TeV
THBINS = np.linspace(0.0, np.pi, 91)
NEV_MAX = 200                                   # per-frame event-count histogram range
SEQ_MAX = 200_000

B = 'hepmc3_event/'
BRANCHES = {
    'pid': B + 'particles/particles.pid',
    'st': B + 'particles/particles.status',
    'px': B + 'particles/particles.momentum.m_v1',
    'py': B + 'particles/particles.momentum.m_v2',
    'pz': B + 'particles/particles.momentum.m_v3',
    'vt': B + 'vertices/vertices.position.m_v4',
    'l1': B + 'links1',
    'l2': B + 'links2',
}


def fingerprint(px, py, pz, pid):
    h = px.view(np.uint64) * np.uint64(1000003)
    h ^= py.view(np.uint64) * np.uint64(7919)
    h ^= pz.view(np.uint64)
    h ^= pid.astype(np.uint64) * np.uint64(2654435761)
    return h


def main():
    merged, out, statuses = sys.argv[1], sys.argv[2], [int(s) for s in sys.argv[3].split(',')]
    tree = uproot.open(merged)['hepmc3_tree']
    rec = {s: dict(nev=[], nfs=[], tev=np.zeros(len(TBINS) - 1), tfs=np.zeros(len(TBINS) - 1),
                   p=np.zeros(len(PBINS) - 1), th=np.zeros(len(THBINS) - 1),
                   pid={}, seq=[], nseq=0, t_out=0)
           for s in statuses}
    other = []  # per frame: particles of no listed source
    frames = 0
    with np.errstate(over='ignore'):
        for batch in tree.iterate(list(BRANCHES.values()), step_size=25, library='np'):
            for i in range(len(batch[BRANCHES['st']])):
                e = {k: np.asarray(batch[b][i]) for k, b in BRANCHES.items()}
                frames += 1
                n = len(e['st'])
                l1, l2 = e['l1'], e['l2']
                # links: particle (+id, 1-based) -> vertex (-id) is the particle's
                # end vertex; vertex -> particle is its production vertex.
                prod = np.full(n, -1)
                end = np.full(n, -1)
                m = (l1 < 0) & (l2 > 0)
                prod[l2[m] - 1] = -l1[m] - 1
                m = (l1 > 0) & (l2 < 0)
                end[l1[m] - 1] = -l2[m] - 1
                vt_ns = e['vt'] / C_MM_PER_NS
                known = np.zeros(n, bool)
                for s, r in rec.items():
                    fs = e['st'] == s + 1
                    beam = e['st'] == s + 4
                    known |= (e['st'] >= s) & (e['st'] < s + 1000)
                    ev_vtx = np.unique(end[beam & (end >= 0)])
                    r['nev'].append(len(ev_vtx))
                    r['nfs'].append(int(fs.sum()))
                    r['tev'] += np.histogram(vt_ns[ev_vtx], TBINS)[0]
                    pv = prod[fs]
                    r['tfs'] += np.histogram(vt_ns[pv[pv >= 0]], TBINS)[0]
                    px, py, pz, pid = e['px'][fs], e['py'][fs], e['pz'][fs], e['pid'][fs]
                    pt = np.hypot(px, py)
                    r['p'] += np.histogram(np.hypot(pt, pz), PBINS)[0]
                    r['th'] += np.histogram(np.arctan2(pt, pz), THBINS)[0]
                    u, c = np.unique(pid, return_counts=True)
                    for a, b in zip(u.tolist(), c.tolist()):
                        r['pid'][a] = r['pid'].get(a, 0) + b
                    if r['nseq'] < SEQ_MAX and len(px):
                        take = min(SEQ_MAX - r['nseq'], len(px))
                        r['seq'].append(fingerprint(px[:take], py[:take], pz[:take], pid[:take]))
                        r['nseq'] += take
                other.append(int((~known).sum()))
    arrays = {'frames': np.array(frames), 'statuses': np.array(statuses), 'other': np.array(other),
              'tbins': TBINS, 'pbins': PBINS, 'thbins': THBINS}
    pids = {}
    for s, r in rec.items():
        arrays[f'{s}_nev'] = np.array(r['nev'], dtype=np.int32)
        arrays[f'{s}_nfs'] = np.array(r['nfs'], dtype=np.int32)
        for k in ('tev', 'tfs', 'p', 'th'):
            arrays[f'{s}_{k}'] = r[k]
        arrays[f'{s}_seq'] = np.concatenate(r['seq']) if r['seq'] else np.zeros(0, np.uint64)
        pids[str(s)] = r['pid']
    arrays['pid_json'] = np.array(json.dumps(pids))
    np.savez_compressed(out, **arrays)
    print(f'extract: {frames} frames, sources {statuses} -> {out}')


if __name__ == '__main__':
    main()
