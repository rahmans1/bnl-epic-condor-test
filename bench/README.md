# Merger benchmark: SignalBackgroundMerger vs TimeFrameBuilder

The question: do the two background mergers that this repo supports
(`-M hepmcmerger` and `-M timeframebuilder`) produce the same merged
background frames? Their random number generators differ, so the frames
cannot match exactly. "The same" is tested in four ways:

1. **Same input events, in the same order.** For every source, the
   sequence of final-state particles each merger wrote. Each particle is
   fingerprinted by its exact momentum bits and PDG code. Different seeds
   and different counts per frame do not change this sequence, so it should
   be identical position for position.
2. **Same rates.** Events placed per 2000 ns frame, against rate × window
   and against each other. This includes the Poisson shape (var/mean = 1)
   and a two-sample chi2 on the distribution of events per frame.
3. **Same time placement.** The time of each placed event within the frame
   should be uniform over 0–2000 ns in both.
4. **Same content.** Final-state |p|, polar angle and production time per
   source.

Also measured: wall time, CPU time and peak memory of the merge step (prmon)
at 100, 500 and 1000 frames per job.

Only the merge step is benchmarked. npsim and eicrecon are the same in both
modes (the 26.07.3 image, the same seeds), and the merged HepMC3 file is
the only thing the merger hands them.

## Reproduce

From an SDCC submit node (e.g. `eicsub01`), at the repo root:

    CHUNKS=60 FRAMES=100 SCALING="500 1000" bench/run_benchmark.sh submit
    # wait until condor_q shows none of them
    FRAMES=100 SCALING="500 1000" RESULTS=bench/results/f100 bench/run_benchmark.sh analyze

The results below used exactly those settings. Without them, the defaults
are: config `configs/allbg_10x275_gold10um.env`, 20 chunks × 500 frames per
merger, plus 3 chunks each at 100 and 1000 frames for the scaling plot.
Runs go to `bench/runs/f<frames>/<sample>/bench-<merger>/`.

At 500 or more frames, stock TimeFrameBuilder 0.9.2 needs more than 6 GB
(`memory/README.md`). Its jobs get held: raise their request with
`condor_qedit <cluster> RequestMemory 16000` and `condor_release <cluster>`,
or submit with `-m 16000`. The patched build (`MERGER_PATH=...`) fits in
the default.

What a benchmark job does (`submit.sh -X`):

1. The merge step, exactly as a production job of this workflow runs it:
   `bgmix_payload.sh merge` through `mergers/<merger>.sh`, in the merger's
   image.
2. `bench/extract.py` in the analysis image reads the merged file and
   writes a small `BENCH/<sample>.<chunk>.bench.npz`. The merged file itself
   is dropped (it is about 2.3 MB per frame; `-H` keeps it).

`analyze` runs two scripts:

- `bench/source_info.py` reads the first 1000 events of each source file
  and records the file's event count and its beam end vertices per event.
  `extract.py` counts placed events by beam end vertices, and a proton
  beam-gas event has two, so its counts are divided by 2.
- `bench/compare.py` makes the plots, `summary.json` and `summary.md`.

To run the analysis by hand, in the 26.07.3 image:

    python3 bench/source_info.py <runs>/f500/<sample>/bench-hepmcmerger results/source_info.json
    python3 bench/compare.py --a <runs>/f500/<sample>/bench-hepmcmerger \
        --b <runs>/f500/<sample>/bench-timeframebuilder \
        --sources results/source_info.json --scaling <other bench run dirs> --out results

## Results

Run on 2026-11-05: 10x275, all five backgrounds, 2000 ns frames.
SignalBackgroundMerger (SBM) is HEPMC_Merger 2.4.0 in eic_xl 26.07.3.
TimeFrameBuilder (TFB) is 0.9.2 in eic_xl 26.11.0. Both had the same seeds
and skips. The comparison uses the 47 chunks × 100 frames (4,700 frames)
that both mergers finished. The remaining 13 TFB chunks were still queued.
Everything is in `results/f100/` (`summary.md`, `summary.json`, plots).

**Verdict:** the two mergers give statistically the same merged frames. In
all but one chunk they also read the very same input events in the same
order. That one chunk exposed a skip bug in SBM, not in TFB.

### 1. Same input events, same order (`input_sequence.png`)

The final-state particle sequence is identical position for position,
chunk by chunk:

- proton beam-gas: 47/47 chunks
- brems: 47/47
- Coulomb: 46/46 (one chunk had none)
- Touschek: 47/47
- SYNRAD: 46/47

That covers up to 200,000 particles per source per chunk. TFB 0.9.2's
event index advances once per event, so the old "advanced twice per event"
issue is gone.

**The SYNRAD exception, chunk 24, is an SBM bug.** Its SYNRAD skip is
about 2,206,217,000, above 2³¹−1 (2,147,483,647):

1. HEPMC_Merger v2.4.0 parses `--bgFile` skips as `long long`
   (`SignalBackgroundMerger.cpp:157`).
2. It then passes them to `PrepData(..., int skip, ...)` (`:419`), which
   narrows the value to about −2.09 billion.
3. `applySmartSkip` treats any skip ≤ 0 as no skip (`:514`), so SYNRAD was
   read from event 0, silently.

TFB takes skips as 64-bit and wrapped the skip correctly (mod 832,375).

A skip between 2³¹ and 2³² becomes negative and is dropped. A larger skip
is reduced mod 2³² before the file-size wrap, so it starts at the wrong
event.

The production payload builds skips the same way (`run.sh`: rate × chunk
offset + a random number up to 2³¹−1). So production jobs whose skip for a
high-rate source exceeds 2³¹ can get the same silent fallback. How many
production jobs are affected has not been checked. That
matters little for SYNRAD itself, since every frame reuses the same
832k-photon pool. It would matter for a high-rate source with a long file.

Two possible fixes:
- in HEPMC_Merger, make `PrepData`'s `skip` a `long long`;
- in `run.sh`, reduce the skip modulo 2³¹−1.

### 2. Same rates (`rates.png`, `events_per_frame.png`)

| source | expected / frame | SBM / frame | TFB / frame | var/mean SBM | var/mean TFB | SBM vs TFB, events-per-frame p |
|---|---|---|---|---|---|---|
| p beam-gas | 0.0652 | 0.0660 ± 0.0038 | 0.0647 ± 0.0037 | 1.03 | 0.98 | 0.13 |
| SYNRAD | 26,554 | 26,552 ± 2.3 | 26,556 ± 2.4 | 0.97 | 1.01 | 0.49 |
| e-gas brems | 6.354 | 6.362 ± 0.036 | 6.347 ± 0.037 | 0.98 | 1.01 | 0.08 |
| e Coulomb | 0.0591 | 0.0634 ± 0.0038 | 0.0545 ± 0.0034 | 1.06 | 1.00 | 0.14 |
| e Touschek | 0.467 | 0.457 ± 0.010 | 0.473 ± 0.010 | 0.99 | 1.01 | 0.25 |

Both mergers match rate × window within 1.3 σ for every source, and
var/mean ≈ 1, as Poisson placement should give. Proton beam-gas counts are
divided by 2, because each Pythia event has two beam particles
(`source_info.json`).

### 3. Same time placement (`event_time.png`)

The event start time is uniform over 0–2000 ns in both mergers. The
SBM-vs-TFB chi2 test passes for every source: p = 0.27 (proton), 0.42,
0.45, 0.38, 0.19.

### 4. Same content (`momentum.png`, `theta.png`, `particle_time.png`)

|p| and polar angle agree (p = 0.9–1), as they must when the input
particles are the same. Particle production time agrees too (p = 0.13 to
0.45) once chi2 is divided by the particles per event. Without that
correction it fails spuriously: chi2/ndf comes out at about 2 for brems and
about 20 for proton beam-gas, which are exactly their multiplicities.

### Performance (`performance.png`, `results/memory_vs_frames.png`)

| frames per job | SBM wall / CPU / peak PSS | TFB 0.9.2 wall / CPU / peak PSS |
|---|---|---|
| 100 | 54 s / 47 s / 2.2 GB | 70 s / 47 s / 3.3 GB |
| 500 | 332 s / 234 s / 2.3 GB | 289 s / 228 s / 8.0 GB |
| 1000 | 699 s / 478 s / 2.2 GB | 713 s / 446 s / 13.4 GB |

CPU time is about the same. Wall time includes streaming the inputs from
JLab. TFB's memory grows about 11 MB per frame: it leaks a file reader
every time a background file wraps. The 7-line patch fixes it (1.9 GB at
500 frames, output bit-identical). See `memory/README.md`.

### Merger choice

Physics-wise, either merger can be used: their output frames are
statistically the same. Two practical caveats:
- Stock TFB 0.9.2 needs the `close()` patch, or about 100 frames per job,
  to fit in 6 GB.
- SBM mishandles background skips above 2³¹−1 without any message.
