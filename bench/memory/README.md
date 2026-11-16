# TimeFrameBuilder memory growth

## Symptom

In the merge-only benchmark (10x275, all five backgrounds), peak PSS of the
merge step was:

| frames per job | SignalBackgroundMerger | TimeFrameBuilder 0.9.2 |
|---|---|---|
| 100 | 1.8–2.2 GB | 2.8–3.2 GB |
| 500 | 1.8–2.3 GB | over 6 GB (all 20 jobs held at the 6 GB limit; about 7.3 GB once rerun with more memory) |

SignalBackgroundMerger levels off within the first 40 s. TimeFrameBuilder
keeps growing by 150–270 MB steps until the job ends. Only the merge step
is affected: npsim and eicrecon are separate processes that run after the
merger exits, on the same merged file whichever merger wrote it.

## Cause (from the source)

TimeFrameBuilder v0.9.2 (`eic/TimeFrameBuilder`, tag v0.9.2 = 257e714, the
build in eic_xl 26.11.0) with HepMC3 3.3.0:

1. `HepMC3DataSource::openNextFile()` (src/HepMC3DataSource.cc) makes a new
   reader every time a source reaches the end of its file and repeats
   (`repeat_on_eof`):

       reader_ = std::make_shared<HepMC3::ReaderRootTree>(input_file);

   The old reader is dropped without `close()`.
2. HepMC3 3.3.0's `ReaderRootTree` (rootIO/src/ReaderRootTree.cc) has **no
   destructor**. Its constructor runs `TFile::Open`, and only `close()` calls
   `m_file->Close()`. A reader dropped without `close()` therefore keeps
   its TFile open, along with the TTree, the baskets it has read and the
   `GenEventData` buffers it allocated.
3. The SYNRAD source has 832,375 events and is drawn at about 26,550 per
   2 us frame, so it reaches the end of its file about every 31 frames. A
   100-frame job opened it 5 times (once at the start, once more to apply
   the wrapped skip, then 3 wraps). A 500-frame job opens it about 18 times.

SignalBackgroundMerger is not affected: its memory is flat at any frame
count.

## Isolated reproduction

`reopen_leak.py` opens the SYNRAD file with `ReaderRootTree`, reads 30,000
events (about one frame), drops the reader, and repeats 5 times. Run in
eic_xl 26.11.0:

    F=root://dtn2304.jlab.org:8443//jlab-osdf-ro/eic/EPIC/volatile/EVGEN/BACKGROUNDS/SYNRAD/dataprod_rel_1.0.0/10x275/GoldCoating/10um/dataprod_rel_1.0.0_synrad_10x275_run001.preproc_10000repeats.hepmc3.tree.root
    python3 reopen_leak.py $F 5 30000 drop     # as TimeFrameBuilder does
    python3 reopen_leak.py $F 5 30000 close    # close() before dropping

Result (PSS after each open + 30k events):

| open | drop (TFB's way) | close first |
|---|---|---|
| 1 | 514 MB | 442 MB |
| 2 | 710 MB | 520 MB |
| 3 | 905 MB | 524 MB |
| 4 | 1101 MB | 524 MB |
| 5 | 1296 MB | 524 MB |

That's about 196 MB lost per reopen without `close()`, and flat memory
with it.

In the real jobs, TFB's growth is larger than that test predicts. Median
peaks were 3.05, 7.71 and 13.1 GB at 100, 500 and 1000 frames, against a
flat 1.95–1.99 GB for SignalBackgroundMerger (`plot_memory.py`,
`../results/memory_vs_frames.png`). That's about 11 MB per frame. One leaked
reader per SYNRAD wrap at about 0.2 GB would be about 6.5 MB per frame.

Two things don't fit yet:
- A dropped reader in a real job has read the whole file, not 30k events,
  so it may hold more.
- The PSS staircase steps about every 18 frames, not every 31.

The patched build below settled it: with the old reader closed, memory is
flat, so the reopen leak is the whole cause of the growth. The real jobs
just leak more per reopen than the 30k-event test, because each dropped
reader has read through the whole file first.

## Proposed fix

`tfb-close-reader.patch`, against v0.9.2: close and reset the previous
reader in `openNextFile()` before making the new one. It changes no event
order or content, since the file is reread from the same position. The
proper upstream fix in HepMC3 would be a `ReaderRootTree` destructor that
closes and deletes the file. Both fixes should be reported upstream.

**Verified** on 2026-11-05 (cluster 320665): the patch was built from
v0.9.2 in eic_xl 26.11.0, in `tfb-patched/build/` (at the repo root). Three chunks
of 500 frames were run with `MERGER_PATH` set to that directory, using the
same seeds and skips as the stock TFB 500-frame run:

| | peak PSS, 500 frames | request needed |
|---|---|---|
| stock TFB 0.9.2 | 7.71 GB (median of 20) | over 6 GB (all 20 held) |
| patched TFB | 1.90 GB (median of 3), flat after about 30 s | fits in the 6 GB default |
| SignalBackgroundMerger | 1.99 GB (median of 20) | fits |

The output is unchanged: in all 3 chunks, every array in
`bench/extract.py`'s summary (42 per chunk) is exactly equal to stock
TFB's, so the patch changes memory only.

To rebuild:

    # at the repo root
    git clone https://github.com/eic/TimeFrameBuilder tfb-patched && cd tfb-patched
    git checkout v0.9.2 && git apply ../bench/memory/tfb-close-reader.patch
    apptainer exec -B /gpfs02,/gpfs/mnt/gpfs02 /cvmfs/singularity.opensciencegrid.org/eicweb/eic_xl:26.11.0-stable \
      bash -c "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTIMEFRAME_BUILDER_VERSION=0.9.2 && cmake --build build -j8"

To use it in a run:

    MERGER_PATH=$PWD/build ../submit.sh -c ... -M timeframebuilder ...

To redraw the plot:

    python3 bench/memory/plot_memory.py bench/runs bench/results/memory_vs_frames.png   # repo root, 26.07.3 image

## Other notes from the source

These came up while reading the source and don't affect this workflow's
single-file sources:

- **Multi-file sources:** `loadNextEvent` reopens when `current_entry_index_
  >= total_entries_`, but on a normal end of file it never increments
  `m_current_file`, and `total_entries_` only counts files opened so far.
  So a source with several input files rereads its first file. The
  production note "end of file reopening the same file" still applies to
  multi-file sources in 0.9.2.
- **Wrap logic:** in the `repeat_on_eof` branch, the index computed for the
  right file is overwritten by `m_current_file = 0`. Harmless with one
  file.
- **Skips larger than a file:** handled with one modulo and one reopen in
  0.9.2, not by recursion per file length.
- **Event index:** advanced once per event (`DataHandler::mergeEvents`).
  The benchmark's sequence test confirms this: SYNRAD and brems sequences
  match SignalBackgroundMerger's particle for particle.
- **Short output:** a source without repeat that runs out ends the job
  early with exit 0 (`updateInputNEvents` returns false, then `run()`
  finalizes). The workflow's frame-count check (exit 87) catches this.
