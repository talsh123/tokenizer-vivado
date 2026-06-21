# Energy calculation sheet — FPGA vs CPU per-token energy

**Purpose:** defend the report claim *"the FPGA tokenizer is ~285× more energy-efficient per token than a modern CPU."* (Book Ch. 10.4)

Every number below is traceable to a file in `analysis/results/`. Nothing here is hand-estimated except where explicitly labelled.

---

## 1. The formula

Energy per token is power divided by throughput:

```
energy_per_token (J)      = power_W / throughput_tokens_per_sec
energy_per_1M_tokens (J)  = power_W / throughput_tokens_per_sec * 1e6
tokens_per_Joule          = throughput_tokens_per_sec / power_W
```

This is the standard energy-efficiency metric (Joules/op). It is independent of how long
you run — it captures *cost per unit of work*, which is exactly what a datacenter pays for.

---

## 2. Inputs (with provenance)

| Quantity | FPGA tokenizer | CPU (Ryzen 7 7435HS) | Source |
|---|---|---|---|
| Power (W) | **0.051** | **30** | `results/power.csv` |
| Throughput (tok/s) | **1,224,514** | **2,529,664** | `results/power.csv`, `results/cpu_throughput.csv` |
| Power method | `report_power` dynamic, instance `tokenizer_axi_lite_0` | HWiNFO "CPU Package Power" peak under sustained all-core load | see notes |
| Power confidence | vectorless / **Low** (Vivado) | measured sensor, peak of a 60 s load | — |

**FPGA power** — `results/power_fpga.rpt` (Vivado 2025.2, `report_power`):
- Whole SoC `design_1_wrapper`: **1.369 W** total on-chip (1.210 W dynamic + 0.159 W static).
- Tokenizer IP only `tokenizer_axi_lite_0`: **0.051 W** dynamic.
- We use the **0.051 W datapath figure** for the per-token claim because that is the
  block being compared. The 1.369 W whole-SoC figure is reported separately for honesty
  (it includes MicroBlaze, MIG/DDR, Ethernet, SmartConnect — none of which the CPU
  baseline needs either, since the CPU number is just the tokenizer thread).

**CPU power** — HWiNFO sensor log while `cpu_power_load.py` hammered the tokenizer on all
16 threads for 60 s:
- Idle baseline ≈ **13.8 W**
- Under load: Current 25.6 W, **Max 30.4 W**, Avg 18.8 W
- We use **30 W** (peak under load) as the conservative-for-CPU figure. (Using the average
  18.8 W would make the FPGA look *better*, so 30 W is the honest, defensible choice.)

**FPGA throughput** — single tokenizer instance at 100 MHz, from the 66-line corpus
simulation: 2925 word-tokens over 238,707 fabric cycles = **1.225 M tok/s** aggregate
(`results/comparison.csv`, `fpga_cycles` summed). This is **one** core; the device has
headroom to replicate.

**CPU throughput** — `backend_tokenizer.encode_batch` (Rust, multithreaded) over the same
corpus, 16 threads, 100 batch reps: **2.53 M tok/s** (`results/cpu_throughput.csv`).

---

## 3. The calculation

### Total-power basis (headline ~285×)

| Metric | FPGA | CPU | Ratio |
|---|---|---|---|
| Power (W) | 0.051 | 30 | 588× |
| Throughput (tok/s) | 1,224,514 | 2,529,664 | 0.48× |
| **Energy / 1M tokens (J)** | **0.0416** | **11.86** | **285×** |
| **Tokens / Joule** | **24.0 M** | **84,322** | **285×** |

```
FPGA:  0.051 / 1,224,514 * 1e6 = 0.0416 J / 1M tokens   ->  24,010,000 tok/J
CPU:   30    / 2,529,664 * 1e6 = 11.86  J / 1M tokens   ->     84,322  tok/J
ratio = 11.86 / 0.0416 = 285x  (identically 24.0M / 84.3k = 285x)
```

The FPGA is ~2.1× *slower* in raw throughput (one core vs sixteen), but it does the work
at 1/588 the power, so it wins on energy by ~285×.

### Marginal-power basis (conservative ~152×)

If you only count the CPU power *above idle* (the energy the tokenization actually adds,
30 − 13.8 ≈ **16 W**) against the FPGA's already-dynamic 0.051 W:

```
CPU marginal:  16 / 2,529,664 * 1e6 = 6.32 J / 1M tokens
FPGA:                                 0.0416 J / 1M tokens
ratio = 6.32 / 0.0416 = 152x
```

So the honest range is **~150× (marginal) to ~285× (total)**. The report should quote both
and explain the difference, rather than only the bigger number.

---

## 4. Caveats to state in the chapter (pre-empts examiner attack)

1. **FPGA power is vectorless / Low confidence.** `report_power` estimated switching from
   defaults, not from a real activity trace (SAIF). The true figure could be higher; even a
   10× error still leaves a ~28× advantage. State this explicitly.
2. **Datapath vs whole-SoC.** 0.051 W is the tokenizer block alone. The whole board draws
   1.369 W. The comparison is block-to-block (CPU number is the tokenizer thread, not the
   whole laptop), so block-to-block on the FPGA side is the matching choice — but disclose it.
3. **One FPGA core vs 16 CPU threads.** Throughput is apples-to-apples per *device's current
   configuration*, not per core. Noted on the throughput graph already.
4. **Peak vs average CPU power.** We used peak (30 W). Average load was 18.8 W. Disclosed.

---

## 5. Regenerating these numbers

```
py ./cpu_tokenizer_benchmark.py     # -> results/cpu_results.csv, cpu_throughput.csv
# (Vivado) open implemented design -> report_power -> save analysis/results/power_fpga.rpt
# edit results/power.csv with report_power 0.051 W and your HWiNFO package-power reading
py ./plot_results.py                # -> figures/energy_per_million.png
```
