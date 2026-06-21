#!/usr/bin/env python3
"""
compare_results.py  --  merge the CPU and FPGA measurements into one table.

Reads results/cpu_results.csv (HuggingFace) and results/fpga_results.csv (xsim fabric),
joins them per corpus line, and writes results/comparison.csv with, per line:
  chars, token counts, exact-match flag, CPU core/overhead latency + jitter, and the FPGA
  fabric latency (fabric_cycles x 10 ns at 100 MHz). Also prints the headline summary
  (exact-match %, punctuation-omission %, aggregate throughput). No heavy deps -- pure csv.
"""
import csv
import os
import sys

HERE   = os.path.dirname(os.path.abspath(__file__))
R      = os.path.join(HERE, "results")
CLK_HZ = 100e6
NS_PER_CYC = 1e9 / CLK_HZ            # 10 ns per cycle at 100 MHz


def norm(s):
    return " ".join(s.split())       # collapse whitespace / strip trailing space


def load(path):
    if not os.path.exists(path):
        sys.exit(f"missing {path} -- run the CPU benchmark and the xsim TB first")
    with open(path, encoding="utf-8-sig", newline="") as f:
        return {int(r["idx"]): r for r in csv.DictReader(f)}


def main():
    cpu  = load(os.path.join(R, "cpu_results.csv"))
    fpga = load(os.path.join(R, "fpga_results.csv"))

    out, nmatch = [], 0
    tot_bert = tot_word = tot_punct = 0
    mismatched = []
    for idx in sorted(fpga):
        c, g = cpu[idx], fpga[idx]
        match = (norm(c["fpga_expected_ids"]) == norm(g["fpga_ids"]))
        nmatch += match
        if not match:
            mismatched.append(idx)
        fcyc = int(g["fabric_cycles"])
        tot_bert  += int(c["bert_tokens"])
        tot_word  += int(c["fpga_expected_tokens"])
        tot_punct += int(c["punct_tokens"])
        out.append({
            "idx": idx,
            "chars": int(c["chars"]),
            "bert_tokens": int(c["bert_tokens"]),
            "expected_tokens": int(c["fpga_expected_tokens"]),
            "fpga_tokens": int(g["tokens"]),
            "punct_tokens": int(c["punct_tokens"]),
            "match": int(match),
            "cpu_core_us": float(c["core_median_us"]),
            "cpu_core_min_us": float(c["core_min_us"]),
            "cpu_core_max_us": float(c["core_max_us"]),
            "cpu_core_jitter_us": float(c["core_jitter_us"]),
            "cpu_ovh_us": float(c["ovh_median_us"]),
            "cpu_ovh_jitter_us": float(c["ovh_jitter_us"]),
            "fpga_cycles": fcyc,
            "fpga_us": round(fcyc * NS_PER_CYC / 1000.0, 3),
        })

    with open(os.path.join(R, "comparison.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0].keys()))
        w.writeheader()
        w.writerows(out)

    N = len(out)
    sum_chars = sum(r["chars"] for r in out)
    sum_tok   = sum(r["fpga_tokens"] for r in out)
    sum_fcyc  = sum(r["fpga_cycles"] for r in out)
    secs      = sum_fcyc * NS_PER_CYC / 1e9
    fpga_cps  = sum_chars / secs                               # chars/sec aggregate
    fpga_tps  = sum_tok / secs                                 # tokens/sec aggregate

    print(f"Lines           : {N}")
    print(f"Exact match     : {nmatch}/{N}  ({100*nmatch/N:.1f}%)"
          + (f"   mismatches at idx {mismatched}" if mismatched else ""))
    print(f"Token breakdown : {tot_bert} BERT = {tot_word} word + {tot_punct} punctuation "
          f"({100*tot_punct/tot_bert:.1f}% omitted by the FPGA by design)")
    print(f"FPGA throughput : {fpga_cps/1e6:.2f} M chars/s, {fpga_tps/1e3:.1f} k tokens/s "
          f"(single core, 100 MHz, aggregate incl. per-line pipeline latency)")
    tp = os.path.join(R, "cpu_throughput.csv")
    if os.path.exists(tp):
        with open(tp, encoding="utf-8-sig") as f:
            r = next(csv.DictReader(f))
        print(f"CPU throughput  : {float(r['chars_per_sec'])/1e6:.2f} M chars/s, "
              f"{float(r['tokens_per_sec'])/1e6:.2f} M tokens/s batched ({r['threads']} threads)")
    print("\nWrote results/comparison.csv")


if __name__ == "__main__":
    main()
