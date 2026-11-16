#!/usr/bin/env python3
"""Per source of a bench run: events in the file, and beam-particle end
vertices per event, which extract.py counts as placed events (a proton
beam-gas Pythia event has two beams with an end vertex each, every other
source one). compare.py divides its event counts by this number.

    source_info.py <bench run dir> <out.json> [events to read, default 1000]
"""
import collections
import json
import os
import re
import sys

import numpy as np
import uproot

run_dir, out = sys.argv[1], sys.argv[2]
nread = int(sys.argv[3]) if len(sys.argv) > 3 else 1000
env = dict(re.match(r'^([A-Z_]+)=(.*)$', l.strip()).groups()
           for l in open(os.path.join(run_dir, 'run.env')) if re.match(r'^[A-Z_]+=', l))
sources = [{'file': env['SIGNAL_FILE'], 'status': int(env['SIGNAL_STATUS'])}]
sources += json.load(open(os.path.join(run_dir, 'backgrounds.json')))
info = {}
for src in sources:
    t = uproot.open(src['file'])['hepmc3_tree']
    a = t.arrays(['hepmc3_event/particles/particles.status', 'hepmc3_event/links1', 'hepmc3_event/links2'],
                 entry_stop=nread, library='np')
    c = collections.Counter()
    for st, l1, l2 in zip(*a.values()):
        end = np.full(len(st), -1)
        m = (l1 > 0) & (l2 < 0)
        end[l1[m] - 1] = -l2[m] - 1
        c[len(np.unique(end[(st == 4) & (end >= 0)]))] += 1
    k, n = c.most_common(1)[0]
    info[str(src['status'])] = {'file': src['file'], 'entries': int(t.num_entries),
                                'beam_vertices_per_event': int(k), 'fraction_with_that': n / sum(c.values()),
                                'events_read': int(sum(c.values()))}
    print(src['status'], os.path.basename(src['file']), info[str(src['status'])])
json.dump(info, open(out, 'w'), indent=1)
