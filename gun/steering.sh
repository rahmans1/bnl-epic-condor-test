#!/bin/bash
# Write the npsim steering of one particle gun to stdout.
#
#   gun/steering.sh <particle> <energy, e.g. 20*GeV> <theta_min_deg> <theta_max_deg>
#
# This is the swf-epicprod template copied line for line:
# swf_epicprod/payload/evgen_generate.py, GUN_HEADER and gun_steering(), the
# angle-range branch (commit 5fddcb9). That is the production team's
# hand-written steering: a cos(theta) gun between the two angles in
# degrees, at a fixed total energy (mass included) from the origin along +z.
# npsim's command line sets the event count and the seed; the steering
# sets neither.
set -euo pipefail
PARTICLE=${1:?particle}
ENERGY=${2:?energy, e.g. 20*GeV}
THETA_MIN=${3:?theta min in degrees}
THETA_MAX=${4:?theta max in degrees}
cat <<STEER
from DDSim.DD4hepSimulation import DD4hepSimulation
from g4units import mm, GeV, MeV, degree
SIM = DD4hepSimulation()
SIM.gun.energy = ${ENERGY}
SIM.gun.particle = "${PARTICLE}"
SIM.gun.position = (0.0, 0.0, 0.0)
SIM.gun.direction = (0.0, 0.0, 1.0)
SIM.gun.distribution = "cos(theta)"
SIM.gun.thetaMin = ${THETA_MIN}*degree
SIM.gun.thetaMax = ${THETA_MAX}*degree
STEER
