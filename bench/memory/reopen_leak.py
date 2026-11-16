"""Open a HepMC3 ROOT-tree file with ReaderRootTree, read N events, drop the
reader (as TimeFrameBuilder's openNextFile does on every wrap), repeat; print
the process PSS after each cycle. With 'close', call close() before dropping."""
import gc, sys
from pyHepMC3 import HepMC3 as hm
from pyHepMC3.rootIO import HepMC3 as hmr
path, cycles, nread, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
def pss_mb():
    for l in open('/proc/self/smaps_rollup'):
        if l.startswith('Pss:'): return int(l.split()[1]) / 1024
evt = hm.GenEvent()
print(f'{mode}: start {pss_mb():.0f} MB', flush=True)
for c in range(cycles):
    r = hmr.ReaderRootTree(path)
    for i in range(nread):
        r.read_event(evt)
    if mode == 'close':
        r.close()
    del r; gc.collect()
    print(f'{mode}: after open #{c+1} + {nread} events: {pss_mb():.0f} MB', flush=True)
