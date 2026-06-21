#!/usr/bin/env python3
"""
cpu_tokenizer_benchmark.py

Measures HuggingFace bert-base-uncased tokenization latency on the CPU for the
EXACT three texts used to benchmark the FPGA DMA tokenizer, so the final report
can compare FPGA latency vs CPU latency apples-to-apples.

For each text it prints:
  - token count + token IDs, to VERIFY they match the FPGA output, and
  - median single-call latency (microseconds) for:
      * BertTokenizerFast  -- Rust-backed 'tokenizers' lib, the tough real-world competitor
      * BertTokenizer      -- pure-Python reference, shows the naive algorithmic cost
  - the FPGA on-board number and the resulting speed multiples.

Notes on fairness:
  - add_special_tokens=False: the FPGA does NOT emit [CLS]/[SEP], so neither do we
    (pangram = 9 tokens, not 11). The printed IDs must match what the board returned.
  - Single call = one sentence at a time, matching how the FPGA processes one input.
  - Warm timings only (first calls pay lazy-init/caching costs); median beats GC/noise.
  - Run on an otherwise-idle machine and record your CPU model + clock for the report.
"""

import time
import statistics
import csv
import platform
import sys

try:
    from transformers import BertTokenizer, BertTokenizerFast
except ImportError:
    sys.exit("Missing dependency. Install with:  pip install transformers")

MODEL = "bert-base-uncased"

# The EXACT three texts benchmarked on the FPGA (must match byte-for-byte).
TEXTS = [
    ("pangram",   "the quick brown fox jumps over the lazy dog"),
    ("subword",   "tokenization of unbelievable embeddings is remarkably straightforward"),
    ("paragraph", "machine learning models process natural language by converting words "
                  "into numerical tokens that represent subword units learned from a large "
                  "training corpus"),
]

# FPGA DMA latencies you measured on-board (microseconds), for the side-by-side table.
# >>> update these if you re-measure <<<
FPGA_US = {"pangram": 70.0, "subword": 54.0, "paragraph": 72.0}

WARMUP      = 200
ITERS_FAST  = 20000   # fast tokenizer call is tens of us -> many iters to beat timer noise
ITERS_SLOW  = 2000    # pure-Python call is ~ms -> fewer iters keeps the run short


def median_us(encode_fn, text, iters):
    for _ in range(WARMUP):
        encode_fn(text)
    samples = []
    for _ in range(iters):
        t0 = time.perf_counter_ns()
        encode_fn(text)
        samples.append(time.perf_counter_ns() - t0)
    return statistics.median(samples) / 1000.0  # ns -> us


def main():
    print("CPU:", platform.processor() or "(unknown -- fill in for the report)")
    print("Python:", platform.python_version())
    print(f"Loading {MODEL} (first run downloads the vocab) ...\n")

    fast = BertTokenizerFast.from_pretrained(MODEL)
    slow = BertTokenizer.from_pretrained(MODEL)

    enc_fast = lambda t: fast.encode(t, add_special_tokens=False)
    enc_slow = lambda t: slow.encode(t, add_special_tokens=False)

    rows = []
    for name, text in TEXTS:
        ids = enc_fast(text)
        us_fast = median_us(enc_fast, text, ITERS_FAST)
        us_slow = median_us(enc_slow, text, ITERS_SLOW)
        fpga = FPGA_US.get(name)

        print(f"[{name}]  {len(text)} chars, {len(ids)} tokens")
        print(f"  ids:       {' '.join(map(str, ids))}")
        print(f"  CPU fast:  {us_fast:9.2f} us   (BertTokenizerFast, Rust)")
        print(f"  CPU slow:  {us_slow:9.2f} us   (BertTokenizer, pure Python)")
        if fpga:
            print(f"  FPGA DMA:  {fpga:9.2f} us   (on-board)")
            print(f"   -> FPGA vs CPU-fast: {us_fast / fpga:5.1f}x"
                  f"   |   FPGA vs CPU-slow: {us_slow / fpga:5.1f}x")
        print()
        rows.append([name, len(text), len(ids),
                     round(us_fast, 2), round(us_slow, 2), fpga])

    with open("tokenizer_benchmark.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["text", "chars", "tokens", "cpu_fast_us", "cpu_slow_us", "fpga_dma_us"])
        w.writerows(rows)
    print("Wrote tokenizer_benchmark.csv")


if __name__ == "__main__":
    main()
