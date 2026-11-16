# bnl-epic-condor-test

ePIC simulation and reconstruction as local HTCondor jobs on BNL SDCC
(`group_eic`). The jobs skip PanDA and Rucio: inputs stream from the JLab
OSDF door, and outputs land on GPFS. The steps follow the epicprod payload
(swf-epicprod `swf_epicprod/payload/run.sh`).

There are three modes, and each one is picked by the config:

| Mode | Config | Each event is |
|---|---|---|
| Background only | `configs/allbg_*.env` | one 2 µs frame of every beam background at its real rate, with no physics signal |
| Particle gun | `configs/singles_*.env` (`MODE=gun`) | one gun particle, the swf-epicprod singles steering |
| Gun + background overlay | a gun config with `-B configs/allbg_*.env` | one gun particle plus one frame of every background |

## Quick start

From an SDCC submit node (e.g. `eicsub01`), with the repo on GPFS. The jobs
read the scripts from where they sit and mount only `/gpfs02`:

    # background only: 100 jobs x 100 frames, SignalBackgroundMerger
    ./submit.sh -c configs/allbg_10x275_gold10um.env -n 100 -f 100

    # particle gun: 50k each of pi+ and neutron, 20 GeV, 1-4 deg, 5x41
    ./submit.sh -c configs/singles_20GeV_1to4deg.env

    # the same gun with the 10x275 backgrounds overlaid
    ./submit.sh -c configs/singles_20GeV_1to4deg.env -B configs/allbg_10x275_gold10um.env

    # any mode: -d writes the run directory and .sub file without submitting
    ./submit.sh -c configs/singles_20GeV_1to4deg.env -e 20 -n 2 -o test-out -d

`./submit.sh -c <bg config>` with no other arguments prints the options of
background-only mode. `gun/submit_gun.sh` with no arguments prints the gun
options.

## Layout

| Path | What it is |
|---|---|
| `submit.sh` | Entry point. Writes the run directory and the `.sub` file, then calls `condor_submit`. A `MODE=gun` config is handed to `gun/submit_gun.sh`. |
| `job.sh`, `bgmix_payload.sh` | Background-only Condor executable and its steps: `merge`, `simreco`, `extract` (benchmark), and `gunevgen` (overlay). |
| `gun/` | Gun mode. `submit_gun.sh`, `gun_job.sh`, `gun_payload.sh`, `steering.sh` (the swf-epicprod steering template), and `gun_hepmc.py` (the gun as HepMC3, for the overlay). |
| `mergers/` | The production merger adapters, copied unchanged from swf-epicprod `swf_epicprod/payload/mergers/` (3b8cef0). |
| `configs/` | One sample per file. |
| `config_data/` | Campaign background-source JSONs, from eicweb `EIC/campaigns/datasets`. |
| `bench/` | The merger benchmark (SignalBackgroundMerger vs TimeFrameBuilder) and the TimeFrameBuilder memory study. |

## Output and resubmission

Each run directory holds `run.env`, the `.sub` file, the Condor logs
(`condor/`), `RECO/`, and `LOG/` (stage logs and prmon output, one tarball
per chunk). With `-F` it also gets `FULL/` (edm4hep), and with `-H`,
`HEPMC/` (merged frames). Where the run directory goes:

- Background only: `out/<sample>/<merger>/`
- Gun: `out/SINGLE/<particle>/<energy>/<min>to<max>deg/`, the same layout as production's EVGEN/SINGLE
- Overlay: `out/SINGLE_BG/<bg sample>/<merger>/<particle>/<energy>/<min>to<max>deg/`

A chunk whose RECO file already exists exits at once, so resubmitting a
whole range fills in only the failed chunks. `-s` extends a run. A run
directory refuses to be extended with a different configuration (chunk
size, image, merger, sources, steering). Use another `-o` for that.

## Background-only mode

    ./submit.sh -c CONFIG -n CHUNKS [-f FRAMES] [-s FIRST] [-M hepmcmerger|timeframebuilder] [-m MB] [-F] [-H] [-X] [-d]

- **Merge:** the merger takes one signal and up to four backgrounds. The
  proton beam-gas row (status 6000) becomes the "signal" at its real rate.
  The other four sources (SYNRAD 2000, brems 3000, Coulomb 4000, Touschek
  5000) stay backgrounds.
- **Signal blocks:** neither merger wraps the signal file, so each chunk
  reads its own block of signal events (mean + 6σ + 10). `submit.sh`
  refuses a range that would run past `SIGNAL_NEVENTS`.
- **Flags:** background skips, seeds (chunk + 1), status offsets and the
  npsim/eicrecon flags are the same as in run.sh.
- **Merger choice:** `-M hepmcmerger` runs SignalBackgroundMerger in
  `CONTAINER` (26.07.3), the production default. `-M timeframebuilder`
  runs `timeframe_builder` 0.9.2 in `TFB_CONTAINER` (26.11.0; the first
  image that has it is 26.08.0). Simulation and reconstruction run in
  `CONTAINER` in both cases, with the same seeds, so chunk N of one merger
  pairs with chunk N of the other.
- **`-X`:** the merge-only benchmark (`bench/README.md`).

## Gun mode

    ./submit.sh -c configs/singles_*.env [-n CHUNKS] [-e EVENTS] [-p "PARTICLES"] [-s FIRST] [-m MB] [-F] [-d]

- **Steering:** the swf-epicprod template, line for line (`evgen_generate.py`
  `gun_steering()`, angle-range branch, 5fddcb9). A `cos(theta)` gun between
  `GUN_THETA_MIN` and `GUN_THETA_MAX` degrees, at total energy `GUN_ENERGY`
  (mass included), from the origin along +z in the detector frame. npsim
  runs it with `--runType run --enableGun --steeringFile`.
- **Seeds:** as in run.sh, `(sha256(stem)[:7] * 10000 + chunk + 1) mod (2^31-1)`.
  Each particle and each chunk get their own stream, the same one production
  would draw for the same stem.
- **Geometry:** `DETECTOR_CONFIG_EBEAMxPBEAM`. Singles use 5x41, as in production.
- **Chunks:** `GUN_EVENTS` per particle in chunks of `EVENTS_PER_CHUNK`
  (2000, production's gun `events_per_job`).

## Gun + background overlay (`-B`)

    ./submit.sh -c configs/singles_*.env -B configs/allbg_*.env [-M timeframebuilder|hepmcmerger] [-e FRAMES] [-H] ...

- **Gun events:** `gun/gun_hepmc.py` writes the chunk's gun particles as
  HepMC3 ASCII, with the template's kinematics. The kinematics match the
  npsim gun in distribution but not event for event. The file is ASCII
  because pyHepMC3's ROOT-tree writer segfaults in 26.07.3.
- **Merge:** the gun is the merger's signal at frequency 0, so exactly one
  per frame. Every source of the background config is a background. The
  10x275 config has five sources, more than SignalBackgroundMerger takes,
  so the default merger is `timeframebuilder`. It uses `tfb-patched/build`
  if that exists (below) or `MERGER_PATH` if set. `-M hepmcmerger` works
  only with four or fewer sources.
- **Geometry:** the background config's beams (10x275), because the
  backgrounds are beam-specific. 5x41 has no background set.
- **Seeds:** the gun's per-stem seed drives the gun kinematics, the
  background skips and Geant4.
- **Cost:** each frame carries about 26k SR photons, so a frame costs far
  more than a bare gun event. `OVERLAY_EVENTS_PER_CHUNK` (100) sets the
  chunk size.

## TimeFrameBuilder status and the patched build

The production payload treats TimeFrameBuilder as validation only. The
benchmark against 0.9.2 (`bench/README.md`) found:

- **Physics:** merged frames are statistically identical to
  SignalBackgroundMerger's, and both read the same input events in the
  same order.
- **Fixed in 0.9.2:** the double event-index advance, and skips beyond the
  end of a file.
- **Still open:** multi-file sources reread their first file (not used
  here). A source without repeat that runs out exits 0 with short output;
  the frame-count check catches this (exit 87).
- **Memory leak:** stock 0.9.2 leaks memory every time a background file
  repeats, about 11 MB per frame here. Above about 250 frames per job that
  passes 6 GB. Use the patched build, or keep stock TFB to about 100 frames
  per job.

The fix is commit `f8bba31` on branch `fix/hepmc3-close-reader-on-reopen`
of `eic/TimeframeBuilder`, also in `bench/memory/tfb-close-reader.patch`.
Build it inside the repo (`tfb-patched/` is gitignored) and in
`TFB_CONTAINER`, because it links against that image's libraries:

    git clone -b fix/hepmc3-close-reader-on-reopen https://github.com/eic/TimeframeBuilder.git tfb-patched
    cd tfb-patched
    apptainer exec -B /gpfs02,/gpfs/mnt/gpfs02 \
      /cvmfs/singularity.opensciencegrid.org/eicweb/eic_xl:26.11.0-stable bash -c \
      "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTIMEFRAME_BUILDER_VERSION=0.9.2 && cmake --build build -j8"

Then pass `MERGER_PATH=$PWD/tfb-patched/build` (environment or config).
Overlay mode picks it up on its own. The build peaks at 1.9 GB at 500
frames, and its output is bit-identical to stock 0.9.2. `MERGER_PATH` is
part of a run directory's identity, so use a new `-o` when switching between
the stock and patched builds. A job's `condor/<chunk>.out` shows
`merger from <MERGER_PATH>`.

When an image ships the fix, point `TFB_CONTAINER` at it, drop `MERGER_PATH`,
and confirm with `./submit.sh -c ... -n 3 -f 500 -M timeframebuilder -X -o bench/runs/check`.
Peak PSS should be about 2 GB, not about 8 GB. Test the memory rather than
trusting the version string.

## Tested

- **Background only, 2026-11-05.** 10x275, 2 chunks × 2 frames per merger
  (clusters 320654-320656); every job exited 0.
  - About 9 min per chunk. npsim took 3.3 min and eicrecon 1.4 min; the merge took 12-14 s once the JLab door was warm.
  - Peak PSS: eicrecon 2.6 GB, npsim 2.3 GB, merger 1.1 GB.
  - SYNRAD primaries per frame: 26,632 / 26,613 with hepmcmerger and 26,419 / 26,814 with TFB, against about 26,554 expected.
  - A rerun reproduced hepmcmerger chunk 1 exactly, so the seeds are deterministic.
- **Gun and overlay:** test runs pending.

## Caveats

- **SYNRAD reuse:** the gold 10 µm SYNRAD file holds about 31 frames of
  photons, so every frame reuses the same 832k-photon pool.
- **10x100 sources:** the 10x100 JSON uses the 10x275 SYNRAD, Coulomb and
  Touschek files, as the campaign does.
- **Signal events:** `SIGNAL_NEVENTS` (10M) is confirmed for the 275 GeV
  proton beam-gas file. The 100 GeV file was not checked.
- **Skip overflow:** SignalBackgroundMerger silently mishandles background
  skips above 2³¹−1 (HEPMC_Merger 2.4.0 `PrepData(int skip)`). For SYNRAD
  this starts after about 81,000 frames. TimeFrameBuilder takes 64-bit skips.
- **eicrecon errors:** eicrecon logs "No beam electrons/protons found" in
  frames with no physics signal. This is expected; the jobs still succeed.
