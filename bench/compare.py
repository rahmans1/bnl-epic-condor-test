#!/usr/bin/env python3
"""Compare SignalBackgroundMerger and TimeFrameBuilder from merge-only
benchmark runs (submit.sh -X), and write plots and a summary (bench/README.md).

    compare.py --a RUN_DIR_A --b RUN_DIR_B --sources SOURCE_INFO.json \
               [--scaling RUN_DIR ...] --out DIR

RUN_DIR_A/B are the two modes' bench-<merger> run directories with the same
sample, frames and chunks. --scaling adds further bench run directories (any
frames, either merger) to the timing and memory plots only. SOURCE_INFO.json
is source_info.py's: extract.py counts beam-particle end vertices, and a
source whose events have k of them (proton beam-gas: 2) is divided by k.
"""
import argparse
import glob
import io
import json
import os
import re
import tarfile

import numpy as np
from scipy import stats

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt  # noqa: E402

NAMES = {2000: 'SYNRAD', 3000: 'e-gas brems', 4000: 'e Coulomb', 5000: 'e Touschek',
         6000: 'p beam-gas'}
LABEL = {'hepmcmerger': 'SignalBackgroundMerger', 'timeframebuilder': 'TimeFrameBuilder'}
COL = {'hepmcmerger': '#1f77b4', 'timeframebuilder': '#d62728'}


def read_env(run_dir):
    env = {}
    for line in open(os.path.join(run_dir, 'run.env')):
        m = re.match(r'^([A-Z_]+)=(.*)$', line.strip())
        if m:
            env[m.group(1)] = m.group(2)
    return env


def expected_per_frame(run_dir):
    env = read_env(run_dir)
    w = float(env['INTEGRATION_WINDOW'])
    rates = {int(env['SIGNAL_STATUS']): float(env['SIGNAL_FREQ']) * w * 1e-6}
    for row in json.load(open(os.path.join(run_dir, 'backgrounds.json'))):
        rates[int(row['status'])] = float(row['freq']) * w * 1e-6
    return env, rates


def load_mode(run_dir, per_event):
    files = sorted(glob.glob(os.path.join(run_dir, 'BENCH', '*.bench.npz')))
    if not files:
        raise SystemExit(f'no BENCH/*.bench.npz in {run_dir}')
    chunks = {}
    for f in files:
        chunk = int(re.search(r'\.(\d{4})\.bench\.npz$', f).group(1))
        z = np.load(f)
        d = {k: z[k] for k in z.files}
        for s, k in per_event.items():
            if k != 1 and f'{s}_nev' in d:
                if np.any(d[f'{s}_nev'] % k):
                    raise SystemExit(f'{f}: source {s} event count not a multiple of {k}')
                d[f'{s}_nev'] = d[f'{s}_nev'] // k
                d[f'{s}_tev'] = d[f'{s}_tev'] / k
        chunks[chunk] = d
    return chunks


def prmon(run_dir, label):
    """(frames, wall s, cpu s, max PSS GB) of each chunk's prmon summary for label."""
    env = read_env(run_dir)
    out = []
    for tgz in sorted(glob.glob(os.path.join(run_dir, 'LOG', '*.log.tar.gz'))):
        with tarfile.open(tgz) as t:
            for m in t.getmembers():
                if m.name.endswith(f'.{label}.prmon.json'):
                    j = json.load(io.TextIOWrapper(t.extractfile(m)))
                    mx = j.get('Max', {})
                    out.append((int(env['FRAMES']), mx.get('wtime', np.nan),
                                mx.get('utime', 0) + mx.get('stime', 0), mx.get('pss', np.nan) / 1024**2))
    return out


def chi2_two_sample(a, b):
    """Two-sample chi2 for histograms with different totals; (chi2, ndf, p)."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    A, B = a.sum(), b.sum()
    m = (a + b) > 0
    if A == 0 or B == 0 or m.sum() < 2:
        return np.nan, 0, np.nan
    chi2 = (((a * np.sqrt(B / A) - b * np.sqrt(A / B)) ** 2)[m] / (a + b)[m]).sum()
    ndf = int(m.sum() - 1)
    return float(chi2), ndf, float(stats.chi2.sf(chi2, ndf))


def summed(chunks, key):
    return sum(c[key] for c in chunks.values())


def cat(chunks, key):
    return np.concatenate([chunks[k][key] for k in sorted(chunks)])


def step_hist(ax, edges, h, color, label, norm=True, logx=False):
    y = h / h.sum() if norm and h.sum() else h
    ax.stairs(y, edges, color=color, label=label, lw=1.4)
    if logx:
        ax.set_xscale('log')


def ratio(ax, edges, a, b, color='k'):
    A, B = a.sum(), b.sum()
    with np.errstate(divide='ignore', invalid='ignore'):
        r = (b / B) / (a / A)
        e = r * np.sqrt(1 / a + 1 / b)
    c = 0.5 * (edges[1:] + edges[:-1])
    ok = (a > 0) & (b > 0)
    ax.errorbar(c[ok], r[ok], yerr=e[ok], fmt='.', color=color, ms=3, lw=0.8)
    ax.axhline(1, color='grey', lw=0.8)
    ax.set_ylim(0.8, 1.2)
    ax.set_ylabel('TFB / SBM')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--a', required=True, help='bench-hepmcmerger run directory')
    ap.add_argument('--b', required=True, help='bench-timeframebuilder run directory')
    ap.add_argument('--sources', required=True, help='source_info.py output')
    ap.add_argument('--scaling', nargs='*', default=[])
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    envA, rates = expected_per_frame(args.a)
    envB, ratesB = expected_per_frame(args.b)
    for k in ('SAMPLE', 'FRAMES', 'SIGNAL_BLOCK', 'SOURCES', 'INTEGRATION_WINDOW'):
        if envA.get(k) != envB.get(k):
            raise SystemExit(f'runs differ in {k}: {envA.get(k)} vs {envB.get(k)}')
    ma, mb = envA['MERGER'], envB['MERGER']
    src_info = json.load(open(args.sources))
    per_event = {int(s): v['beam_vertices_per_event'] for s, v in src_info.items()}
    A, B = load_mode(args.a, per_event), load_mode(args.b, per_event)
    common = sorted(set(A) & set(B))
    A = {k: A[k] for k in common}
    B = {k: B[k] for k in common}
    statuses = [int(s) for s in A[common[0]]['statuses']]
    frames = {m: int(sum(c['frames'] for c in d.values())) for m, d in ((ma, A), (mb, B))}
    edges = {k: A[common[0]][k] for k in ('tbins', 'pbins', 'thbins')}
    summary = {'sample': envA['SAMPLE'], 'frames_per_chunk': int(envA['FRAMES']), 'chunks': len(common),
               'frames': frames, 'merger_images': {ma: envA['MERGER_CONTAINER'], mb: envB['MERGER_CONTAINER']},
               'beam_vertices_per_event': per_event, 'sources': {}}

    # 1. Rates: events per frame against rate x window, and the Poisson shape.
    fig, axes = plt.subplots(1, len(statuses), figsize=(4 * len(statuses), 3.6))
    for ax, s in zip(axes, statuses):
        na, nb = cat(A, f'{s}_nev'), cat(B, f'{s}_nev')
        mu = rates[s]
        hi = int(max(na.max(), nb.max(), stats.poisson.ppf(0.9999, mu))) + 1
        e = np.arange(hi + 2) - 0.5
        ha, hb = np.histogram(na, e)[0], np.histogram(nb, e)[0]
        k = np.arange(hi + 1)
        ax.stairs(ha / ha.sum(), e, color=COL[ma], label=LABEL[ma], lw=1.4)
        ax.stairs(hb / hb.sum(), e, color=COL[mb], label=LABEL[mb], lw=1.4, ls='--')
        ax.plot(k, stats.poisson.pmf(k, mu), 'k.', ms=4, label=f'Poisson({mu:.4g})')
        ax.set_yscale('log')
        ax.set_title(f'{NAMES.get(s, s)} ({s})')
        ax.set_xlabel('events per frame')
        if mu > 50:
            lo = max(0, int(mu - 5 * np.sqrt(mu)))
            ax.set_xlim(lo, int(mu + 5 * np.sqrt(mu)))
            ax.set_ylim(1e-5, None)
        chi = chi2_two_sample(ha, hb)
        src = {
            'expected_per_frame': mu,
            'mean_per_frame': {ma: float(na.mean()), mb: float(nb.mean())},
            'mean_err': {ma: float(na.std(ddof=1) / np.sqrt(len(na))), mb: float(nb.std(ddof=1) / np.sqrt(len(nb)))},
            'var_over_mean': {ma: float(na.var(ddof=1) / na.mean()) if na.mean() else None,
                              mb: float(nb.var(ddof=1) / nb.mean()) if nb.mean() else None},
            'pull_vs_expected': {m: float((n.mean() - mu) / np.sqrt(mu / len(n))) for m, n in ((ma, na), (mb, nb))},
            'nev_chi2': {'chi2': chi[0], 'ndf': chi[1], 'p': chi[2]},
            'total_events': {ma: int(na.sum()), mb: int(nb.sum())},
            'final_state_particles': {ma: int(cat(A, f'{s}_nfs').sum()), mb: int(cat(B, f'{s}_nfs').sum())},
        }
        summary['sources'][str(s)] = src
    axes[0].legend(fontsize=7)
    fig.suptitle(f'Events per {envA["INTEGRATION_WINDOW"]} ns frame, {frames[ma]} frames per merger')
    fig.tight_layout()
    fig.savefig(os.path.join(args.out, 'events_per_frame.png'), dpi=130)
    plt.close(fig)

    # 2. Mean rate per source: both mergers against expectation.
    fig, ax = plt.subplots(figsize=(7, 3.6))
    x = np.arange(len(statuses))
    for off, m in ((-0.15, ma), (0.15, mb)):
        r = [summary['sources'][str(s)]['mean_per_frame'][m] / rates[s] for s in statuses]
        e = [summary['sources'][str(s)]['mean_err'][m] / rates[s] for s in statuses]
        ax.errorbar(x + off, r, yerr=e, fmt='o', color=COL[m], label=LABEL[m], capsize=3)
    ax.axhline(1, color='grey', lw=0.8)
    ax.set_xticks(x, [f'{NAMES.get(s, s)}\n{rates[s]:.4g}/frame' for s in statuses], fontsize=8)
    ax.set_ylabel('measured / expected rate')
    ax.legend(fontsize=8)
    ax.set_title('Placed events per frame over rate x window')
    fig.tight_layout()
    fig.savefig(os.path.join(args.out, 'rates.png'), dpi=130)
    plt.close(fig)

    # 3-5. Event time, particle |p| and polar angle, with ratio panels.
    for key, edg, xl, logx, fname in (
            ('tev', edges['tbins'], 'event time in frame [ns]', False, 'event_time.png'),
            ('tfs', edges['tbins'], 'final-state production time [ns]', False, 'particle_time.png'),
            ('p', edges['pbins'], '|p| [GeV]', True, 'momentum.png'),
            ('th', edges['thbins'], 'polar angle [rad]', False, 'theta.png')):
        fig, axes = plt.subplots(2, len(statuses), figsize=(4 * len(statuses), 4.8),
                                 gridspec_kw={'height_ratios': [3, 1]}, sharex='col')
        for j, s in enumerate(statuses):
            ha, hb = summed(A, f'{s}_{key}'), summed(B, f'{s}_{key}')
            step_hist(axes[0, j], edg, ha, COL[ma], LABEL[ma], logx=logx)
            step_hist(axes[0, j], edg, hb, COL[mb], LABEL[mb], logx=logx)
            axes[0, j].set_title(f'{NAMES.get(s, s)} ({s})')
            ratio(axes[1, j], edg, ha, hb)
            axes[1, j].set_xlabel(xl)
            chi = chi2_two_sample(ha, hb)
            # Particle-level histograms fill one entry per final-state particle,
            # and the particles of one event share its time and are not
            # independent: chi2 is inflated by about the particles per event
            # (the design effect), so it is divided by that before the p-value.
            # Event-level histograms (tev) are left as they are.
            src = summary['sources'][str(s)]
            mult = 1.0
            if key != 'tev':
                nfs = sum(src['final_state_particles'].values())
                nev = sum(src['total_events'].values())
                mult = max(1.0, nfs / nev) if nev else 1.0
            if mult > 1.0 and chi[1]:
                chi = (chi[0] / mult, chi[1], float(stats.chi2.sf(chi[0] / mult, chi[1])))
            src[f'{key}_chi2'] = {'chi2': chi[0], 'ndf': chi[1], 'p': chi[2], 'particles_per_event': mult}
            axes[0, j].text(0.03, 0.95, f'chi2/ndf {chi[0]:.1f}/{chi[1]}' + (f' (/{mult:.1f} per event)' if mult > 1 else '') + f'\np = {chi[2]:.2g}',
                            transform=axes[0, j].transAxes, va='top', fontsize=7)
        axes[0, 0].legend(fontsize=7, loc='lower left')
        fig.tight_layout()
        fig.savefig(os.path.join(args.out, fname), dpi=130)
        plt.close(fig)

    # 6. Input order: identical source events, in the same order, chunk by chunk.
    fig, ax = plt.subplots(figsize=(7, 3.6))
    for j, s in enumerate(statuses):
        same, compared, first_diff = [], 0, []
        for c in common:
            a, b = A[c][f'{s}_seq'], B[c][f'{s}_seq']
            n = min(len(a), len(b))
            compared += n
            if n:
                eq = a[:n] == b[:n]
                same.append(eq.mean())
                first_diff.append(int(np.argmin(eq)) if not eq.all() else n)
        summary['sources'][str(s)]['sequence'] = {
            'particles_compared': int(compared),
            'chunks_identical': int(sum(1 for v in same if v == 1.0)),
            'chunks_compared': len(same),
            'min_fraction_identical': float(min(same)) if same else None,
        }
        if same:
            ax.plot(np.full(len(same), j) + np.linspace(-0.25, 0.25, len(same)), same, 'o', ms=4, color='k')
    ax.set_xticks(range(len(statuses)), [NAMES.get(s, s) for s in statuses], fontsize=8)
    ax.set_ylabel('fraction of positions identical')
    ax.set_ylim(-0.05, 1.05)
    ax.set_title('Final-state particle sequence, TFB vs SBM, per chunk')
    fig.tight_layout()
    fig.savefig(os.path.join(args.out, 'input_sequence.png'), dpi=130)
    plt.close(fig)

    # 7. Timing and memory of the merge step (prmon), with the scaling runs.
    perf = {}
    for d in [args.a, args.b] + args.scaling:
        m = read_env(d)['MERGER']
        perf.setdefault(m, []).extend(prmon(d, m))
    fig, axes = plt.subplots(1, 3, figsize=(12, 3.6))
    summary['performance'] = {}
    for m, rows in perf.items():
        if not rows:
            continue
        r = np.array(rows, float)
        for ax, col, yl in ((axes[0], 1, 'wall time [s]'), (axes[1], 2, 'CPU time [s]'), (axes[2], 3, 'max PSS [GB]')):
            ax.plot(r[:, 0] * (1 + (0.03 if m == mb else -0.03)), r[:, col], 'o', color=COL[m], label=LABEL[m], ms=4)
            ax.set_xscale('log')
            ax.set_xlabel('frames per job')
            ax.set_ylabel(yl)
        by = {}
        for f, w, c, p in rows:
            by.setdefault(int(f), []).append((w, c, p))
        summary['performance'][m] = {str(f): {'jobs': len(v), 'wall_s_median': float(np.median([x[0] for x in v])),
                                              'cpu_s_median': float(np.median([x[1] for x in v])),
                                              'pss_gb_max': float(np.max([x[2] for x in v]))}
                                     for f, v in sorted(by.items())}
    axes[0].legend(fontsize=8)
    fig.suptitle('Merge step, per job (prmon); wall time includes streaming the inputs from JLab')
    fig.tight_layout()
    fig.savefig(os.path.join(args.out, 'performance.png'), dpi=130)
    plt.close(fig)

    json.dump(summary, open(os.path.join(args.out, 'summary.json'), 'w'), indent=1)
    write_markdown(summary, statuses, ma, mb, args.out)
    print(open(os.path.join(args.out, 'summary.md')).read())


def write_markdown(s, statuses, ma, mb, out):
    L = [f"# Merger comparison: {s['sample']}", '',
         f"{s['chunks']} chunks x {s['frames_per_chunk']} frames per merger "
         f"({s['frames'][ma]} frames each). SBM = {LABEL[ma]}, TFB = {LABEL[mb]}.", '',
         '| source | expected / frame | SBM / frame | TFB / frame | pull SBM | pull TFB | var/mean SBM | var/mean TFB | events-per-frame p |',
         '|---|---|---|---|---|---|---|---|---|']
    for st in statuses:
        r = s['sources'][str(st)]
        v = r['var_over_mean']
        L.append(f"| {NAMES.get(st, st)} | {r['expected_per_frame']:.5g} | "
                 f"{r['mean_per_frame'][ma]:.5g} ± {r['mean_err'][ma]:.2g} | {r['mean_per_frame'][mb]:.5g} ± {r['mean_err'][mb]:.2g} | "
                 f"{r['pull_vs_expected'][ma]:+.2f} | {r['pull_vs_expected'][mb]:+.2f} | "
                 f"{v[ma] if v[ma] is None else round(v[ma], 3)} | {v[mb] if v[mb] is None else round(v[mb], 3)} | "
                 f"{r['nev_chi2']['p']:.3g} |")
    L += ['', 'Event time p is a test over independent events. The particle-level tests (production time, |p|,',
          'theta) have chi2 divided by the mean final-state particles per event (they share the event time),',
          'so their p-values are approximate. The sequence columns show whether the two mergers placed the very',
          'same input particles in the same order.', '',
          '| source | event time p | particle time p | abs(p) p | theta p | sequence: chunks identical | min fraction identical |',
          '|---|---|---|---|---|---|---|']
    for st in statuses:
        r = s['sources'][str(st)]
        q = r['sequence']
        L.append(f"| {NAMES.get(st, st)} | {r['tev_chi2']['p']:.3g} | {r['tfs_chi2']['p']:.3g} | {r['p_chi2']['p']:.3g} | "
                 f"{r['th_chi2']['p']:.3g} | {q['chunks_identical']}/{q['chunks_compared']} | {q['min_fraction_identical']} |")
    L += ['', '| merger | frames/job | jobs | wall s (median) | CPU s (median) | max PSS GB |', '|---|---|---|---|---|---|']
    for m, by in s.get('performance', {}).items():
        for f, v in by.items():
            L.append(f"| {LABEL[m]} | {f} | {v['jobs']} | {v['wall_s_median']:.0f} | {v['cpu_s_median']:.0f} | {v['pss_gb_max']:.2f} |")
    open(os.path.join(out, 'summary.md'), 'w').write('\n'.join(L) + '\n')


if __name__ == '__main__':
    main()
