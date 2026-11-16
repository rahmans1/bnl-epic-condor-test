---
name: epic-condor-run
description: Run, test, monitor and check ePIC simulation jobs on BNL SDCC HTCondor with this repo. Covers background-only mixed frames, particle-gun singles (any particle, energy, theta range), and guns overlaid on beam backgrounds. Use when someone asks to run or submit singles, a particle gun, backgrounds, an overlay, or a new angular or energy configuration; to check job status or outputs; or to resubmit failed chunks. Also use it when someone wants to learn the commands: show or explain them, or write a reusable script, without running anything.
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
- **Explain the flags they'll use** (`-c -B -p -e -n -s -o -d -F -H -m`), and where each result lands on disk.
- **Use their real values:** particle, energy, angles, config file name, absolute paths. Don't use placeholders where you know the value.
- **Scripts:** if they ask for one, write it in the repo root (e.g. `run_<name>.sh`) with `set -euo pipefail`, the dry run first, and a comment block at the top. Don't run it unless they ask.

When you do run commands for them, show each command before running it, so
they can reuse it.

## 1. Pick the mode and the config

| The user wants | Mode | Config | Geometry |
|---|---|---|---|
| Single particles (gun) | plain gun | `configs/singles_*.env` (`MODE=gun`) | **5x41** (default) |
| Single particles on top of the beam backgrounds | overlay | a gun config plus `-B configs/allbg_*.env` | the background config's (10x275 / 10x100) |
| Beam backgrounds only, no physics | background only | `configs/allbg_<beams>_gold10um.env` | the background config's (10x275 / 10x100) |

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

1. **Dry run** (`-d`): writes the run directories and `.sub` files and submits nothing. Check the printed `geometry`, `chunks` and `output` lines against the request. The `geometry` line must say `epic_craterlake_5x41.xml` for a plain gun and the background config's beams (e.g. `epic_craterlake_10x275.xml`) for an overlay.

       ./submit.sh -c configs/<gun>.env -d
       ./submit.sh -c configs/<gun>.env -B configs/allbg_10x275_gold10um.env -d

2. **Small test** into a throwaway output base (`-o test-out`). The queue can sit idle for hours, so run one chunk directly on the submit node instead of through Condor. Plain gun:

       ./submit.sh -c configs/<gun>.env -p <one particle> -e 3 -n 1 -o test-out -d
       _CONDOR_SCRATCH_DIR=$PWD/test-out/scratch gun/gun_job.sh 0 $PWD/test-out/SINGLE/<particle>/<energy>/<min>to<max>deg

   Overlay: the same with `-B ...` and `-e 2`; the run directory is under `test-out/SINGLE_BG/...`. Always pass the run directory as an absolute path. Background only: `./submit.sh -c configs/allbg_...env -n 1 -f 2 -o test-out -d`, then `_CONDOR_SCRATCH_DIR=$PWD/test-out/scratch ./job.sh 0 $PWD/test-out/<sample>/<merger>`.

   A chunk takes about 3 minutes, almost all of it start-up. Run it in the background.

3. **Check the test output** with `tools/check_reco.py` (step 4). Don't submit the full run until the test shows the right particle, angles and energy, and, for an overlay, exactly one status-1 gun particle per frame plus backgrounds.

4. **Full run:** the same command without `-d`, `-o test-out`, `-e` or `-n`. The chunk count comes from `GUN_EVENTS / EVENTS_PER_CHUNK` (2000 per job for the plain gun, `OVERLAY_EVENTS_PER_CHUNK` = 100 for the overlay). Report the cluster IDs and the output directories.

Delete `test-out/` once you're done with it; it is gitignored.

## 3. Monitor

    tools/status.sh            # every run dir under ./out: RECO written / chunks, Condor idle/run/held, failed stages
    tools/status.sh test-out

Jobs often sit idle: `group_eic` is shared, and only slots with at least
`request_memory` (6000 MB by default) match. `condor_q -better-analyze <cluster>.0`
shows how many slots match. Idle is not an error. Don't change memory
requests or remove jobs without asking.

To wait for a cluster to finish without polling in a loop, run one
background command: `until [ -z "$(condor_q <ids> -af ClusterId)" ]; do sleep 120; done; condor_history <ids> -af ClusterId ExitCode | sort | uniq -c`.

## 4. Check outputs

    apptainer exec --cleanenv -B /gpfs02,/gpfs/mnt/gpfs02 \
      /cvmfs/singularity.opensciencegrid.org/eicweb/eic_xl:26.07.3-stable \
      python3 tools/check_reco.py <RECO file> [max_events]

It prints, per event: the gun particles (status 1) with PDG, theta, |p| and
time, plus counts by generator status. Status codes: 1 gun, 4 beams
(overlay), 2001 SYNRAD, 3001 brems, 4001 Coulomb, 5001 Touschek,
6001 proton beam-gas.

Expected values:
- **Plain gun:** one particle per event, theta within the range, energy as set.
- **Overlay:** one status-1 particle per frame, at a random time within the 2 µs frame (not 0), about 26k status 2001 per frame at 10x275, and a few 3001.

## 5. Failures and resubmission

- A chunk's stage log is inside `LOG/<stem>.<chunk>.log.tar.gz` (`*.stages.log`, plus one log and prmon file per program). `tools/status.sh` prints the last failed stage. Condor stdout/stderr are in `condor/<chunk>.out/.err`.
- Exit codes: 82 gun file, 83 no geometry, 84/85 npsim/eicrecon gave no output, 86 merger missing, 87 wrong merged frame count, 89 copy-out (full table in README).
- **Resubmit by rerunning the same submit command.** Chunks that already have a RECO file exit at once. To extend a run, use `-s <first new chunk> -n <count>`.
- "was set up with X, not Y; use another -o": the run directory belongs to a different configuration. Use another `-o`; never edit `run.env` by hand.
- Held jobs are usually over their memory request. Report them and suggest `condor_qedit <cluster> RequestMemory <MB>` plus `condor_release`, then wait for the user's OK.

## Gotchas found the hard way

- **Container environment:** always run containers with `apptainer exec --cleanenv`. Without it, the host environment breaks ROOT's module cache.
- **SignalBackgroundMerger:** it takes at most 4 backgrounds. The 10x275 overlay has 5, so the overlay uses TimeFrameBuilder.
- **TimeFrameBuilder memory:** stock 0.9.2 leaks memory and passes 6 GB above about 250 frames per job. For bigger overlay or TFB chunks, build the patched TFB into `tfb-patched/` (README) or keep chunks at 100 frames.
- **eicrecon "No beam electrons/protons found":** expected in background-only frames. Not a failure.
