#!/usr/bin/env python3
"""Merge-step memory against frames per job, SignalBackgroundMerger vs
TimeFrameBuilder, from the benchmark runs' prmon records (bench/memory/README.md).

    plot_memory.py <runs dir> <out.png>

Reads every <runs>/f*/<sample>/bench-<merger>/ run directory with a finished
chunk (a BENCH/*.npz), and the chunk's <merger>.prmon.json and .prmon.txt from
its LOG tarball. Run directories whose run.env sets MERGER_PATH (a locally
built merger) are plotted as their own series. Left: peak PSS of each job
against its frames. Right: PSS over the run of the longest job of each series.
"""
import glob
import io
import json
import os
import re
import sys
import tarfile

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt  # noqa: E402

runs, out = sys.argv[1], sys.argv[2]
STYLE = {'hepmcmerger': ('SignalBackgroundMerger', '#1f77b4', 'o'),
         'timeframebuilder': ('TimeFrameBuilder 0.9.2', '#d62728', 's'),
         'timeframebuilder-patched': ('TimeFrameBuilder 0.9.2 + close() patch', '#2ca02c', 'D')}


def env_of(d):
    e = {}
    for line in open(os.path.join(d, 'run.env')):
        m = re.match(r'^([A-Z_]+)=(.*)$', line.strip())
        if m:
            e[m.group(1)] = m.group(2)
    return e


peaks = {}    # series -> list of (frames, peak pss GB)
curves = {}   # series -> (frames, t[s], pss[GB]) of its longest job
for d in sorted(glob.glob(os.path.join(runs, 'f*', '*', 'bench-*'))):
    env = env_of(d)
    merger, frames = env['MERGER'], int(env['FRAMES'])
    series = merger + ('-patched' if env.get('MERGER_PATH') else '')
    for npz in glob.glob(os.path.join(d, 'BENCH', '*.bench.npz')):
        task = os.path.basename(npz)[:-len('.bench.npz')]
        tgz = os.path.join(d, 'LOG', f'{task}.log.tar.gz')
        if not os.path.exists(tgz):
            continue
        with tarfile.open(tgz) as t:
            names = {os.path.basename(m.name): m for m in t.getmembers()}
            js = names.get(f'{task}.{merger}.prmon.json')
            tx = names.get(f'{task}.{merger}.prmon.txt')
            if not js:
                continue
            mx = json.load(io.TextIOWrapper(t.extractfile(js)))['Max']
            peaks.setdefault(series, []).append((frames, mx['pss'] / 1024**2))
            if tx and (series not in curves or frames > curves[series][0]):
                rows = io.TextIOWrapper(t.extractfile(tx)).read().split('\n')
                head = rows[0].split()
                data = np.array([r.split() for r in rows[1:] if r.strip()], float)
                tt = data[:, head.index('Time')] - data[0, head.index('Time')]
                curves[series] = (frames, tt, data[:, head.index('pss')] / 1024**2)

fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 4.4))
summary = {}
for s in ('hepmcmerger', 'timeframebuilder', 'timeframebuilder-patched'):
    if s not in peaks:
        continue
    label, col, mk = STYLE[s]
    p = np.array(peaks[s])
    jit = 1 + 0.04 * (np.random.default_rng(1).random(len(p)) - 0.5)
    a1.scatter(p[:, 0] * jit, p[:, 1], s=14, color=col, marker=mk, alpha=0.45, label=None)
    fr = sorted(set(p[:, 0].astype(int)))
    med = [np.median(p[p[:, 0] == f, 1]) for f in fr]
    a1.plot(fr, med, '-', color=col, marker=mk, lw=2, label=label)
    summary[s] = {int(f): (round(float(m), 2), int((p[:, 0] == f).sum())) for f, m in zip(fr, med)}
    if s in curves:
        f, tt, pss = curves[s]
        a2.plot(tt, pss, color=col, lw=1.5, label=f'{label}, {f} frames')
a1.axhline(6000 / 1024, color='grey', ls=':', lw=1)
a1.text(105, 6000 / 1024 + 0.15, 'default request_memory 6000 MB', fontsize=8, color='grey')
a1.set_xscale('log')
a1.set_xticks([100, 500, 1000], ['100', '500', '1000'])
a1.set_xlabel('frames (2 us) per job')
a1.set_ylabel('merge step peak PSS [GB]')
a1.set_title('Peak memory per job (points), median (line)')
a1.legend(fontsize=8, loc='upper left')
a2.set_xlabel('time since merge start [s]')
a2.set_ylabel('PSS [GB]')
a2.set_title('PSS during the longest job of each merger')
a2.legend(fontsize=8, loc='upper left')
fig.suptitle('Merge step memory, all five 10x275 backgrounds (prmon)', y=1.0)
fig.tight_layout()
fig.savefig(out, dpi=130, bbox_inches='tight')
print(json.dumps(summary, indent=1))
