// Convert HepMC3 ASCII to a HepMC3 ROOT tree (.hepmc3.tree.root).
//
//   hepmc3_to_tree <in.hepmc3> <out.hepmc3.tree.root>
//
// TimeFrameBuilder reads only .hepmc3.tree.root, and pyHepMC3's ROOT-tree
// writer segfaults under cling in eic_xl 26.07.3. gun_hepmc.py therefore
// writes ASCII, and this program, compiled in the job's image against that
// image's HepMC3 (bgmix_payload.sh gunevgen), writes the tree. It prints
// the event count.
#include <HepMC3/GenEvent.h>
#include <HepMC3/ReaderAscii.h>
#include <HepMC3/WriterRootTree.h>
#include <iostream>

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: " << argv[0] << " <in.hepmc3> <out.hepmc3.tree.root>\n";
    return 2;
  }
  HepMC3::ReaderAscii in(argv[1]);
  HepMC3::WriterRootTree out(argv[2]);
  long n = 0;
  while (true) {
    HepMC3::GenEvent ev;
    in.read_event(ev);
    if (in.failed()) break;
    out.write_event(ev);
    ++n;
  }
  in.close();
  out.close();
  std::cout << n << "\n";
  return n > 0 ? 0 : 1;
}
