---
name: epic-condor-run
description: Run, test, monitor and check ePIC simulation jobs on BNL SDCC HTCondor with this repo, in the eic_xl container release the user chooses (it can list the available releases). Covers plain simulation of a generator HepMC3 (EVGEN) file, the same file with beam backgrounds mixed in, particle-gun singles (any particle, energy, theta range), guns overlaid on beam backgrounds, and background-only frames, with either merger (hepmcmerger by default, TimeFrameBuilder on request). Use when someone asks to run, simulate or submit a HepMC3 or EVGEN file, singles, a particle gun, backgrounds, an overlay or background mixing, or a new angular or energy configuration; to see which container releases exist or run in a specific one; to memory-profile a sample; to check job status or outputs; or to resubmit failed chunks. Also use it when someone wants to learn the commands: show or explain them, or write a reusable script, without running anything.
---

# Running ePIC jobs on SDCC Condor with this repo

The repo root is the directory that holds `submit.sh`. Run everything from
there, on an SDCC submit node (e.g. `eicsub01`), with the repo on GPFS: the
jobs read the scripts in place and mount only `/gpfs02` and `/gpfs/mnt/gpfs02`.
`README.md` is the full reference (modes, workflow diagrams, config keys,
exit codes). Read it when something here is not enough.

## Teaching mode: when the user wants to learn the commands

Many users want to run this themselves later. When they ask to be shown,
taught, or given the commands or a script, or say "don't run anything":

- **Don't execute anything:** no dry runs, no submissions. Write the exact commands in the order of sections 1-5 below (config edits, dry run, local test, full run, monitoring, output check), each with a one-line comment on what it does and what output to look for.
- **Explain the flags they'll use** (`-c -B -M -C -p -e -n -s -o -d -F -H -m -R`), and where each result lands on disk.
- **Use their real values:** particle, energy, angles, config file name, absolute paths. Don't use placeholders where you know the value.
- **Scripts:** if they ask for one, write it in the repo root (e.g. `run_<name>.sh`) with `set -euo pipefail`, the dry run first, and a comment block at the top. Don't run it unless they ask.

When you do run commands for them, show each command before running it, so
they can reuse it.

## 1. Pick the mode and the config

| The user wants | Mode | Config | Geometry |
|---|---|---|---|
| A generator HepMC3 (EVGEN) file simulated as is | plain file | `configs/<sample>.env` (`MODE=file`) | the file config's (`DETECTOR_BEAMS`, else `EBEAMxPBEAM`) |
| The same file with beam backgrounds mixed in | file overlay | a file config plus `-B configs/allbg_*.env` | the file config's |
| Single particles (gun) | plain gun | `configs/singles_*.env` (`MODE=gun`) | **5x41** (default) |
| Single particles on top of the beam backgrounds | overlay | a gun config plus `-B configs/allbg_*.env` | the background config's (10x275 / 10x100) |
| Beam backgrounds only, no physics | background only | `configs/allbg_<beams>_gold10um.env` | the background config's (10x275 / 10x100) |

**Merger:** every mode that mixes backgrounds uses `hepmcmerger`
(SignalBackgroundMerger) by default, as production does. Add
`-M timeframebuilder` only when the user asks for TimeFrameBuilder. Both
take any number of background sources.

**Release (container image):** every step of a run uses one eic_xl image,
with the detector release of the same version. Never mix images within a
run or add per-merger images.

- **"Which releases are there?" / "what can I run in?":** run `tools/releases.sh` (`all` for every release) and show the table. It lists each release's detector version and whether it has hepmcmerger and TimeFrameBuilder.
- **Default:** the configs' `CONTAINER`, the latest release. Use it when the user names none, and say which release the run uses.
- **The user picks a release:** add `-C <release>` (e.g. `-C 26.10.0`) to every submit command of that run: dry run, test and full run. Don't edit the configs for a one-off choice. Without `-o` the run goes under `out/release-<release>/`.
- **If unsure which they want** (for example "test this in the release production uses"), show the table and ask.
- **Refusals:** an unknown release, or `-M timeframebuilder` on a release without it (before 26.08.0). Report the message; don't work around it.
- **Patched TimeFrameBuilder:** `tfb-patched/build` is used only with the default image. With `-C`, TimeFrameBuilder runs stock, so keep chunks at 100 frames.
- **A newer release than the configs' default:** tell the user and offer to update `CONTAINER` and `DETECTOR_VERSION` in `configs/*.env`.

For a new generator file, copy `configs/beagle_eAg_9x115_q2_1to10.env` to
a descriptive name and edit only these keys:

- `SAMPLE`: the run directory name. Use the file's stem.
- `SIGNAL_FILE`: a `.hepmc3.tree.root` file, as a GPFS path or a `root://` URL (for example the anonymous OSDF door, `root://dtn2304.jlab.org:8443//jlab-osdf-ro/eic/EPIC/cache/EVGEN/...`).
- `SIGNAL_NEVENTS`: events in the file. Take it from the Rucio `events` metadata, or count the `hepmc3_tree` entries. Don't guess.
- `EVENTS_PER_CHUNK`: events per job (`-e` overrides it).
- `EBEAM`, `PBEAM`, and for ion beams `DETECTOR_BEAMS` (e.g. `9x115_Ag107`). The dry run fails if the image has no such geometry; list the choices with `apptainer exec <CONTAINER> ls /opt/detector/epic-<version>/share/epic/ | grep craterlake_`.

A file overlay (`-B`) needs a background config. Only 10x275 and 10x100 sets
exist. With other beams the submit prints `WARNING backgrounds are for ...`
and goes ahead, keeping the sample's geometry: fine for testing, not
physics. Tell the user when that happens.

For a new gun configuration, copy `configs/singles_20GeV_1to4deg.env` to a
descriptive name and edit only these keys:

- `GUN_PARTICLES`: Geant4 names, space separated, e.g. `"pi+ neutron e- gamma proton kaon0L"`.
- `GUN_ENERGY`: **total** energy with its unit, e.g. `20*GeV`, `500*MeV`. This follows the swf-epicprod template; it is not momentum.
- `GUN_THETA_MIN`, `GUN_THETA_MAX`: **degrees**, detector frame (angle from the detector z axis), flat in cos(theta). Confirm the unit with the user if they don't give one: far-forward requests are often in mrad, and the gun can't take mrad as is.
- `GUN_EVENTS`: events per particle.

**Geometry: 5x41 is the default for singles; a 10 GeV geometry is used only
when backgrounds are involved.** Leave it alone unless the user asks: plain singles use **5x41**
(`EBEAM=5 PBEAM=41`), as in production, even when the user doesn't mention
geometry. The overlay and background-only runs always use the background
config's beams (10x275 or 10x100), because the backgrounds only exist for
those beams; in the overlay the singles config's `EBEAM`/`PBEAM` are
ignored. Say so when you submit an overlay. If a user asks for singles at a
10 GeV geometry without backgrounds, or for an overlay at 5x41, point out
that this differs from the default (no 5x41 background set exists) and ask
before going ahead.

Don't invent new physics settings (distributions, vertex smearing, crossing
angle). The steering is the production template, `gun/steering.sh`. Ask the
user before changing it.

## 2. Always dry-run, then test small, before the full run

1. **Dry run** (`-d`): writes the run directories and `.sub` files and submits nothing. Check the printed `geometry`, `chunks` and `output` lines against the request. The `geometry` line must say `epic_craterlake_5x41.xml` for a plain gun, the background config's beams (e.g. `epic_craterlake_10x275.xml`) for a gun overlay, and the file config's geometry for both file modes.

       ./submit.sh -c configs/<gun>.env -d
       ./submit.sh -c configs/<gun>.env -B configs/allbg_10x275_gold10um.env -d
       ./submit.sh -c configs/<file>.env -n 1 -d
       ./submit.sh -c configs/<file>.env -B configs/allbg_10x100_gold10um.env -n 1 -d

2. **Small test** into a throwaway output base (`-o test-out`). The queue can sit idle for hours, so run one chunk directly on the submit node instead of through Condor. Plain gun:

       ./submit.sh -c configs/<gun>.env -p <one particle> -e 3 -n 1 -o test-out -d
       _CONDOR_SCRATCH_DIR=$PWD/test-out/scratch gun/gun_job.sh 0 $PWD/test-out/SINGLE/<particle>/<energy>/<min>to<max>deg

   Overlay: the same with `-B ...` and `-e 2`; the run directory is under `test-out/SINGLE_BG/...`. Always pass the run directory as an absolute path. File modes: `./submit.sh -c configs/<file>.env [-B ...] -n 1 -e 2 -o test-out -d`, then `_CONDOR_SCRATCH_DIR=$PWD/test-out/scratch ./job.sh 0 <the printed output dir>` (`test-out/FILE/<sample>/plain` or `test-out/FILE_BG/<bg sample>/<merger>/<sample>`). Background only: `./submit.sh -c configs/allbg_...env -n 1 -f 2 -o test-out -d`, then `_CONDOR_SCRATCH_DIR=$PWD/test-out/scratch ./job.sh 0 $PWD/test-out/<sample>/<merger>`.

   A chunk takes about 3 minutes, almost all of it start-up. Run it in the background.

3. **Check the test output** with `tools/check_reco.py` (step 4). Don't submit the full run until the test shows the right particle, angles and energy, and, for an overlay, exactly one status-1 gun particle per frame plus backgrounds.

4. **Full run:** the same command without `-d`, `-o test-out`, `-e` or `-n`. A file run without `-n` covers the whole file (`SIGNAL_NEVENTS / EVENTS_PER_CHUNK` jobs), so confirm the size with the user, or pass `-n`. For guns the chunk count comes from `GUN_EVENTS / EVENTS_PER_CHUNK` (2000 per job for the plain gun, `OVERLAY_EVENTS_PER_CHUNK` = 100 for the overlay). Report the cluster IDs and the output directories.

Delete `test-out/` once you're done with it; it is gitignored.

## 3. Monitor

    tools/status.sh            # every run dir under ./out: RECO written / chunks, Condor idle/run/held, failed stages
    tools/status.sh test-out

Jobs often sit idle: `group_eic` is shared, and only slots with at least
`request_memory` match (default 3500 MB for a plain gun, 6000 MB for the
overlays, the file modes and background-only runs). `condor_q -better-analyze <cluster>.0`
shows how many slots match. Idle is not an error. Don't remove jobs without
asking.

Memory escalates automatically, so don't raise requests up front. Every
`.sub` file has `retry_request_memory`: a job killed for exceeding its
memory is requeued with twice the request, up to `-R` (default 12000 MB),
and is held after 4 starts. For long queues, prefer more jobs with fewer
events (`-e`) at a small `-m` over large requests.

To wait for a cluster to finish without polling in a loop, run one
background command: `until [ -z "$(condor_q <ids> -af ClusterId)" ]; do sleep 120; done; condor_history <ids> -af ClusterId ExitCode | sort | uniq -c`.

## 4. Check outputs

    apptainer exec --cleanenv -B /gpfs02,/gpfs/mnt/gpfs02 \
      /cvmfs/singularity.opensciencegrid.org/eicweb/eic_xl:26.11.0-stable \
      python3 tools/check_reco.py <RECO file> [max_events]

Use the run's own release here (`CONTAINER` in its `run.env`).

It prints, per event: the gun particles (status 1) with PDG, theta, |p| and
time, plus counts by generator status. Status codes: 1 gun, 4 beams
(overlay), 2001 SYNRAD, 3001 brems, 4001 Coulomb, 5001 Touschek,
6001 proton beam-gas.

Expected values:
- **Plain gun:** one particle per event, theta within the range, energy as set.
- **Gun overlay:** one status-1 particle per frame, at a random time within the 2 µs frame (not 0), about 26k status 2001 per frame at 10x275, and a few 3001.
- **File modes:** the generator's own particles (status 1 final state, 4 beams, plus generator-specific codes), and in an overlay the background statuses as well.

**Memory profile.** Each program runs under prmon. For peak memory per
step, read the chunk's log tarball:

    tar -xzOf <run dir>/LOG/<task>.log.tar.gz --wildcards '*npsim.prmon.json' | python3 -c "import json,sys; m=json.load(sys.stdin)['Max']; print({k: round(m[k]/1e6, 2) for k in ('rss','pss')}, 'GB;', m['wtime'], 's')"

The same with `*eicrecon.prmon.json`, and in mixing modes
`*hepmcmerger.prmon.json` or `*timeframebuilder.prmon.json`. A 1-chunk plain
file run of 100 events is the standard memory profile of a new sample.

## 5. Failures and resubmission

- A chunk's stage log is inside `LOG/<stem>.<chunk>.log.tar.gz` (`*.stages.log`, plus one log and prmon file per program). `tools/status.sh` prints the last failed stage. Condor stdout/stderr are in `condor/<chunk>.out/.err`.
- Exit codes: 82 gun file, 83 no geometry, 84/85 npsim/eicrecon gave no output, 86 merger missing, 87 wrong merged frame count, 89 copy-out (full table in README).
- **Resubmit by rerunning the same submit command.** Chunks that already have a RECO file exit at once. To extend a run, use `-s <first new chunk> -n <count>`.
- "was set up with X, not Y; use another -o": the run directory belongs to a different configuration. Use another `-o`; never edit `run.env` by hand.
- **Held jobs:** look at `condor_q -hold <cluster>`. If the reason is the memory retry limit (held after 4 starts), the job needs more than the cap. Report it and suggest resubmitting that range with a higher `-R` or a smaller `-e`/`-f`; wait for the user's OK before changing or releasing anything.

## Gotchas found the hard way

- **Container environment:** always run containers with `apptainer exec --cleanenv`. Without it, the host environment breaks ROOT's module cache.
- **SignalBackgroundMerger source count:** its usage text says "up to four background sources", but 2.4.0 takes any number (five merged fine). Don't switch mergers for that reason.
- **TimeFrameBuilder memory:** only with `-M timeframebuilder`. Stock 0.9.2 (still what 26.11.0 ships) leaks memory and passes 6 GB above about 250 frames per job. For bigger TFB chunks, build the patched TFB into `tfb-patched/` (README) or keep chunks at 100 frames.
- **"Stable particle (PDG: ...) with daughters! ... Cannot Simmulate this MC Record"** in the npsim log: a bad generator record, not a framework failure. Report the sample and chunk; the fix is in the input file.
- **Old run directories:** ones made before the single-image change recorded another image and refuse to be extended. Use a new `-o`.
- **eicrecon "No beam electrons/protons found":** expected in background-only frames. Not a failure.
