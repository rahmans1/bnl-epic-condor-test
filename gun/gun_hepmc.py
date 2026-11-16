#!/usr/bin/env python3
"""Write a particle gun as HepMC3 events, so the merger can overlay it.

    gun_hepmc.py --particle pi+ --energy-gev 20 --theta-min 1 --theta-max 4 \\
                 --events N --seed S --output FILE.hepmc3

The template steering (gun/steering.sh) gives npsim's DDG4 gun. This script
draws the same kinematics: one particle per event from the origin, at a
fixed total energy E (mass included, |p| = sqrt(E^2 - m^2)), cos(theta) flat
between theta_min and theta_max (degrees, detector frame), phi flat in
[0, 2pi). The DDG4 gun's own random stream can't be written out, so the
kinematics match in distribution, not event for event.

Each event holds one particle of status 1 with no explicit vertex, so it
starts at the event origin (0,0,0,0). An explicit vertex with no incoming
particle is malformed HepMC3 ASCII ("not enough implicit vertices"). The merger adds the signal status offset (0 here), and npsim tracks
status 1 as stable.

The output is HepMC3 ASCII, which both mergers read (HepMC3 deduces the
format). pyHepMC3's ROOT-tree writer segfaults under cling in eic_xl
26.07.3, so this script imports no ROOT.
"""
import argparse
import math
import random

from particle import Particle
from pyHepMC3 import HepMC3 as hm

# Geant4 / DDG4 gun names to PDG ids (the names the steering takes).
G4_PDG = {
    'e-': 11, 'e+': -11, 'mu-': 13, 'mu+': -13, 'gamma': 22,
    'pi+': 211, 'pi-': -211, 'pi0': 111, 'kaon+': 321, 'kaon-': -321,
    'kaon0L': 130, 'kaon0S': 310, 'proton': 2212, 'anti_proton': -2212,
    'neutron': 2112, 'anti_neutron': -2112, 'lambda': 3122,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--particle', required=True)
    ap.add_argument('--energy-gev', type=float, required=True)
    ap.add_argument('--theta-min', type=float, required=True, help='degrees')
    ap.add_argument('--theta-max', type=float, required=True, help='degrees')
    ap.add_argument('--events', type=int, required=True)
    ap.add_argument('--seed', type=int, required=True)
    ap.add_argument('--output', required=True)
    a = ap.parse_args()

    if a.particle not in G4_PDG:
        raise SystemExit(f'unknown gun particle {a.particle!r}; known: {", ".join(G4_PDG)}')
    pdg = G4_PDG[a.particle]
    mass = Particle.from_pdgid(pdg).mass / 1000.0  # MeV -> GeV
    if a.energy_gev <= mass:
        raise SystemExit(f'energy {a.energy_gev} GeV is below the {a.particle} mass {mass} GeV')
    pmag = math.sqrt(a.energy_gev ** 2 - mass ** 2)
    cmin = math.cos(math.radians(a.theta_max))
    cmax = math.cos(math.radians(a.theta_min))

    rng = random.Random(a.seed)
    writer = hm.WriterAscii(a.output)
    for i in range(a.events):
        ct = rng.uniform(cmin, cmax)
        st = math.sqrt(max(0.0, 1.0 - ct * ct))
        phi = rng.uniform(0.0, 2.0 * math.pi)
        ev = hm.GenEvent(hm.Units.GEV, hm.Units.MM)
        ev.set_event_number(i)
        part = hm.GenParticle(hm.FourVector(pmag * st * math.cos(phi), pmag * st * math.sin(phi),
                                            pmag * ct, a.energy_gev), pdg, 1)
        part.set_generated_mass(mass)
        ev.add_particle(part)
        writer.write_event(ev)
    writer.close()
    print(f'gun_hepmc: {a.events} {a.particle} (pdg {pdg}, m {mass:.6g} GeV, |p| {pmag:.6g} GeV), '
          f'cos(theta) {a.theta_min}-{a.theta_max} deg, seed {a.seed} -> {a.output}')


if __name__ == '__main__':
    main()
