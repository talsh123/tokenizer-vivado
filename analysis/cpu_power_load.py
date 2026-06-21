#!/usr/bin/env python3
"""
cpu_power_load.py  --  drive a sustained, all-core tokenization load so you can read a stable
"CPU Package Power" in HWiNFO that matches the batched throughput number.

Run this, watch HWiNFO's "CPU Package Power (SMU)" settle, and record the steady value (and
your idle baseline before starting). Energy per token uses this power at the measured throughput.
"""
import time
import os
import sys

try:
    from transformers import BertTokenizerFast
except ImportError:
    sys.exit("Install:  py -m pip install transformers")

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "corpus.txt"), encoding="utf-8") as f:
    lines = [ln.rstrip("\n") for ln in f if ln.strip()]

core = BertTokenizerFast.from_pretrained("bert-base-uncased").backend_tokenizer
core.encode_batch(lines, add_special_tokens=False)        # warm

SECONDS = 60
print(f"Hammering the tokenizer (all cores, batched) for {SECONDS}s.")
print("Watch HWiNFO 'CPU Package Power (SMU)' -- record the steady value. Ctrl+C to stop early.")
end, n = time.time() + SECONDS, 0
try:
    while time.time() < end:
        core.encode_batch(lines, add_special_tokens=False)
        n += 1
except KeyboardInterrupt:
    pass
print(f"done -- {n} batches over the run")
