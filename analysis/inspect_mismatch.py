#!/usr/bin/env python3
"""
inspect_mismatch.py  --  classify every FPGA-vs-CPU token mismatch.

Joins results/cpu_results.csv (fpga_expected_ids = BERT minus punctuation = what the FPGA
should emit) with results/fpga_results.csv (fpga_ids = what the hardware emitted), and for
every line where they differ, decodes BOTH id streams back to WordPiece strings so the
difference is human-readable. This is the "classify before judging" step: it separates real
hardware tokenization bugs from expected limitations.
"""
import csv
import os
import sys

try:
    from transformers import BertTokenizerFast
except ImportError:
    sys.exit("Install:  pip install transformers")

HERE = os.path.dirname(os.path.abspath(__file__))
tok  = BertTokenizerFast.from_pretrained("bert-base-uncased")

with open(os.path.join(HERE, "corpus.txt"), encoding="utf-8") as f:
    lines = [ln.rstrip("\n") for ln in f if ln.strip()]


def load(path, idcol):
    d = {}
    with open(path, encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            ids = [int(x) for x in r[idcol].split()] if r[idcol].strip() else []
            d[int(r["idx"])] = ids
    return d


exp  = load(os.path.join(HERE, "results", "cpu_results.csv"),  "fpga_expected_ids")
fpga = load(os.path.join(HERE, "results", "fpga_results.csv"), "fpga_ids")

mismatches = 0
for idx in sorted(fpga):
    if fpga[idx] == exp.get(idx):
        continue
    mismatches += 1
    e, g = exp.get(idx, []), fpga[idx]
    # first differing position
    k = next((i for i in range(max(len(e), len(g)))
              if i >= len(e) or i >= len(g) or e[i] != g[i]), 0)
    print(f"\n=== idx {idx} ===  expected {len(e)} tok, fpga {len(g)} tok, first diff at #{k}")
    print(f"  text : {lines[idx]!r}")
    print(f"  EXP  : {tok.convert_ids_to_tokens(e)}")
    print(f"  FPGA : {tok.convert_ids_to_tokens(g)}")
    lo, hi = max(0, k - 2), k + 4
    print(f"  diff window  EXP : {tok.convert_ids_to_tokens(e[lo:hi])}")
    print(f"  diff window  FPGA: {tok.convert_ids_to_tokens(g[lo:hi])}")

print(f"\n{mismatches} mismatching line(s) of {len(fpga)} total "
      f"({100*(len(fpga)-mismatches)/len(fpga):.1f}% exact word-token match).")
