#!/usr/bin/env python3
"""Compare two merged EDM4hep files branch by branch.

Usage: compare_merged.py A.edm4hep.root B.edm4hep.root [--tree events]
Exit 0 if every common branch of the tree is identical, 1 otherwise.
Used to check that the Arrow-streamed post-sim merge (tfb_postsim.sh
--transport arrow) matches TFB reading the ROOT files directly.
"""
import argparse
import sys

import awkward as ak
import uproot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--tree", default="events")
    args = ap.parse_args()

    ta = uproot.open(args.a)[args.tree]
    tb = uproot.open(args.b)[args.tree]
    print(f"entries: {ta.num_entries} vs {tb.num_entries}")
    ka, kb = set(ta.keys(recursive=True)), set(tb.keys(recursive=True))
    for name in sorted(ka ^ kb):
        print(f"only in {'A' if name in ka else 'B'}: {name}")

    same = ta.num_entries == tb.num_entries and ka == kb
    checked = 0
    for name in sorted(ka & kb):
        try:
            xa = ta[name].array(library="ak")
            xb = tb[name].array(library="ak")
        except Exception as exc:  # container branches without leaves
            continue
        checked += 1
        try:
            equal = ak.all(ak.ravel(xa == xb)) if len(xa) == len(xb) else False
        except Exception:
            equal = ak.to_list(xa) == ak.to_list(xb)
        if not equal:
            same = False
            print(f"DIFF {name}")
    print(f"{checked} branches compared: {'IDENTICAL' if same else 'DIFFERENT'}")
    return 0 if same else 1


if __name__ == "__main__":
    sys.exit(main())
