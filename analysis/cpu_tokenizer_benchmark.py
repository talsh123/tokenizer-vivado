#!/usr/bin/env python3
"""
cpu_tokenizer_benchmark.py  --  CPU side of the FPGA-vs-CPU tokenizer comparison.

Reads ONE shared corpus (corpus.txt, one text per line) and measures the HuggingFace
bert-base-uncased tokenizer at TWO levels, so the comparison is honest about overhead:

  * CORE      -- the Rust backend (tokenizer.backend_tokenizer), NO transformers wrapper
  * OVERHEAD  -- the full transformers call (tokenizer.encode), Python wrapper included

For each it records median / min / max / std / p99 / jitter. The jitter (run-to-run spread)
is the determinism contrast: the FPGA fabric has effectively zero. It also measures BATCHED
throughput (tokens/s, chars/s), where the multi-threaded Rust core is at its best.

CORRECTNESS (the key subtlety): the FPGA pre-tokenizer treats every non-[a-z0-9] byte as a
word boundary and does NOT emit standalone-punctuation tokens, while BERT does. So per line
we record:
  - bert_ids       : BERT's full ids (with punctuation), no [CLS]/[SEP]
  - fpga_expected  : BERT's ids with punctuation tokens removed  = what the FPGA SHOULD emit
  - punct_tokens   : how many tokens the FPGA omits by design (= len(bert) - len(expected))
The FPGA xsim run emits its own ids; compare_results.py later checks fpga_ids == fpga_expected
(expect ~100% on word tokens) and reports the punctuation omission as a separate, honest number.

Output: results/cpu_results.csv  (+ results/cpu_throughput.csv). Run on an idle machine and
record your CPU model + base/boost clock for the report.
"""
import time
import statistics
import csv
import os
import platform
import sys

try:
    from transformers import BertTokenizerFast
except ImportError:
    sys.exit("Missing dependency. Install with:  pip install transformers")

MODEL      = "bert-base-uncased"
HERE       = os.path.dirname(os.path.abspath(__file__))
CORPUS     = os.path.join(HERE, "corpus.txt")
OUTDIR     = os.path.join(HERE, "results")

WARMUP     = 200
ITERS_CORE = 5000     # per-line iterations for the Rust-core latency
ITERS_OVH  = 5000     # per-line iterations for the transformers-wrapper latency
BATCH_REPS = 100      # repeats of the whole corpus for the throughput measurement


def is_word_piece(piece):
    """True if this BERT piece is a token the FPGA would also emit (an alnum run),
    False for a standalone punctuation/symbol token (which the FPGA drops as a boundary).
    [UNK] is kept -- the FPGA emits it too."""
    if piece == "[UNK]":
        return True
    p = piece[2:] if piece.startswith("##") else piece
    return len(p) > 0 and all(c.isalnum() for c in p)


def bench_stats(fn, arg, iters):
    """Warm, then time `iters` single calls; return latency stats in microseconds."""
    for _ in range(WARMUP):
        fn(arg)
    s = []
    for _ in range(iters):
        t0 = time.perf_counter_ns()
        fn(arg)
        s.append(time.perf_counter_ns() - t0)
    us = sorted(x / 1000.0 for x in s)
    return {
        "median": statistics.median(us),
        "min":    us[0],
        "max":    us[-1],
        "std":    statistics.pstdev(us),
        "p99":    us[min(len(us) - 1, int(0.99 * len(us)))],
        "jitter": us[-1] - us[0],
    }


def main():
    cpu = platform.processor() or "(fill in CPU model + base/boost clock for the report)"
    print("CPU     :", cpu)
    print("Python  :", platform.python_version())
    print("Cores   :", os.cpu_count(), "(batch throughput below is multi-threaded / all-core)")

    if not os.path.exists(CORPUS):
        sys.exit(f"missing corpus: {CORPUS}")
    with open(CORPUS, encoding="utf-8") as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip()]
    bad = [i for i, ln in enumerate(lines)
           if any(ord(c) > 0x7E or ord(c) < 0x20 for c in ln)]
    if bad:
        print(f"WARNING: non-ASCII on corpus line(s) {bad}; the matched comparison expects ASCII.")
    print(f"Loading {MODEL} ...  ({len(lines)} corpus lines)\n")

    fast = BertTokenizerFast.from_pretrained(MODEL)
    core = fast.backend_tokenizer                      # the raw Rust tokenizers.Tokenizer

    enc_core = lambda t: core.encode(t, add_special_tokens=False).ids   # Rust core, no wrapper
    enc_ovh  = lambda t: fast.encode(t, add_special_tokens=False)       # full transformers path

    os.makedirs(OUTDIR, exist_ok=True)
    rows = []
    tot_bert = tot_word = tot_punct = 0

    for idx, text in enumerate(lines):
        bert_ids = enc_ovh(text)
        pieces   = fast.convert_ids_to_tokens(bert_ids)
        expected = [i for i, p in zip(bert_ids, pieces) if is_word_piece(p)]
        n_punct  = len(bert_ids) - len(expected)
        tot_bert  += len(bert_ids); tot_word += len(expected); tot_punct += n_punct

        c = bench_stats(enc_core, text, ITERS_CORE)
        o = bench_stats(enc_ovh,  text, ITERS_OVH)

        print(f"[{idx:2d}] {len(text):4d} chars | bert {len(bert_ids):3d} tok "
              f"(words {len(expected):3d}, punct {n_punct:2d}) | "
              f"core {c['median']:6.2f} us (jit {c['jitter']:7.2f}) | "
              f"ovh {o['median']:6.2f} us (jit {o['jitter']:7.2f})")

        rows.append([
            idx, len(text), len(bert_ids), len(expected), n_punct,
            round(c['median'], 3), round(c['min'], 3), round(c['max'], 3),
            round(c['std'], 3), round(c['p99'], 3), round(c['jitter'], 3),
            round(o['median'], 3), round(o['min'], 3), round(o['max'], 3),
            round(o['std'], 3), round(o['p99'], 3), round(o['jitter'], 3),
            " ".join(map(str, bert_ids)),
            " ".join(map(str, expected)),
        ])

    with open(os.path.join(OUTDIR, "cpu_results.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "idx", "chars", "bert_tokens", "fpga_expected_tokens", "punct_tokens",
            "core_median_us", "core_min_us", "core_max_us", "core_std_us", "core_p99_us", "core_jitter_us",
            "ovh_median_us", "ovh_min_us", "ovh_max_us", "ovh_std_us", "ovh_p99_us", "ovh_jitter_us",
            "bert_ids", "fpga_expected_ids",
        ])
        w.writerows(rows)

    # ---- batched throughput (the Rust core's best case: all cores, amortized overhead) ----
    core.encode_batch(lines, add_special_tokens=False)            # warm
    t0 = time.perf_counter_ns()
    for _ in range(BATCH_REPS):
        core.encode_batch(lines, add_special_tokens=False)
    dt = (time.perf_counter_ns() - t0) / 1e9
    n_tokens = BATCH_REPS * tot_bert
    n_chars  = BATCH_REPS * sum(len(l) for l in lines)
    tps = n_tokens / dt
    cps = n_chars / dt
    with open(os.path.join(OUTDIR, "cpu_throughput.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["cpu", "threads", "tokens_per_sec", "chars_per_sec", "batch_reps", "corpus_lines"])
        w.writerow([cpu, os.cpu_count(), round(tps, 1), round(cps, 1), BATCH_REPS, len(lines)])

    print(f"\nCorpus totals: {tot_bert} BERT tokens, {tot_word} word tokens, "
          f"{tot_punct} punctuation tokens ({100*tot_punct/tot_bert:.1f}% the FPGA omits by design)")
    print(f"Batched throughput (all {os.cpu_count()} cores): "
          f"{tps/1e6:.2f} M tokens/s, {cps/1e6:.2f} M chars/s")
    print(f"\nWrote results/cpu_results.csv  and  results/cpu_throughput.csv")


if __name__ == "__main__":
    main()
