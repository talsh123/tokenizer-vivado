# Benchmark setup & methodology — defends the CPU baseline (Book Ch. 10.3–10.4)

So nobody can say *"your CPU number is unfair."* Both engines see the **same 66-line corpus**
(`analysis/corpus.txt`); only the engine differs.

---

## 1. CPU baseline — `cpu_tokenizer_benchmark.py`

| Setting | Value |
|---|---|
| CPU | **AMD Ryzen 7 7435HS**, 8 cores / 16 threads, 45 W TDP (laptop) |
| Reported by | `AMD64 Family 25 Model 68 Stepping 1, AuthenticAMD` (`cpu_throughput.csv`) |
| Tokenizer | HuggingFace `bert-base-uncased` |
| Core engine | `BertTokenizerFast.backend_tokenizer.encode` — the **Rust** core, no Python wrapper |
| Full-call engine | `BertTokenizerFast.encode` — includes Python wrapper overhead |
| Throughput engine | `backend_tokenizer.encode_batch`, **16 threads**, 100 batch reps |
| Special tokens | `add_special_tokens=False` (no `[CLS]`/`[SEP]`, to match the FPGA) |
| Python | 3.14.0 |

**Why two latency numbers (core vs full call):** the "core" number isolates the actual
tokenization work; the "full call" number includes Python-side overhead. Reporting both is
the apples-to-apples honesty the comparison needs — it shows the FPGA isn't just beating
Python glue, it's compared against the optimized Rust path too.

**Per-line stats** (`bench_stats`): median / min / max / std / p99 / **jitter (max−min)**.
Jitter is the headline determinism argument — the CPU's worst-case latency swings with OS
scheduling; the FPGA's is cycle-exact (jitter = 0).

**Outputs:** `results/cpu_results.csv` (per line), `results/cpu_throughput.csv` (aggregate).

### CPU power load — `cpu_power_load.py`
Drives a sustained all-core batched encode loop for 60 s so HWiNFO shows a *stable*
"CPU Package Power" that matches the batched throughput number. Record idle baseline first.
Measured: idle ≈ 13.8 W, peak 30.4 W, avg 18.8 W under load (used 30 W — see ENERGY_CALCULATION.md).

---

## 2. FPGA baseline — `gen_corpus_tb.py` → `tb_corpus_perf.v`

| Setting | Value |
|---|---|
| Clock | 100 MHz (10 ns/cycle) |
| Stream rate | 1 byte / clock into `s_axis` (8-bit) |
| DUT | `tokenizer_axi_lite` (AXI-Lite tied off; pure streaming path) |
| Measured | `fabric_cycles` = first byte accepted → last token out, per line |
| Latency conversion | `fabric_us = fabric_cycles × 0.01` (10 ns/cycle) |
| Simulator | Vivado xsim (no ModelSim) |

`gen_corpus_tb.py` reads `corpus.txt`, writes `corpus_bytes.mem`, and emits the testbench
that streams every line and `$fwrite`s token IDs + cycle counts to `results/fpga_results.csv`.

**On-silicon cross-check:** the same texts run over TCP through the AXI-DMA firmware path
gave 54–72 µs end-to-end (incl. DMA setup + cache flush). The sim `fabric_us` is the pure
fabric compute; the board number adds DMA/cache overhead. Both are reported (Ch. 10.3.2).

---

## 3. Pipeline order (full reproduce)
```
py ./cpu_tokenizer_benchmark.py     # CPU core+overhead latency, jitter, throughput
py ./gen_corpus_tb.py               # emit corpus_bytes.mem + tb_corpus_perf.v
#   -> run tb_corpus_perf in Vivado xsim -> results/fpga_results.csv
py ./compare_results.py             # merge -> results/comparison.csv (match %, punct %, us)
py ./inspect_mismatch.py            # decode any mismatches (0 after the #2 fix; 2 pre-fix)
py ./plot_results.py                # 5 figures into figures/
```
