#!/usr/bin/env python3
"""
plot_results.py  --  figures for the FPGA-vs-CPU report.

Reads results/comparison.csv (from compare_results.py) and results/cpu_throughput.csv, and
writes PNGs into figures/:
  1. latency_vs_length.png   -- FPGA fabric vs CPU core vs CPU full-call, with CPU jitter band
  2. jitter_vs_length.png    -- CPU run-to-run jitter vs the FPGA's zero (determinism)
  3. throughput.png          -- aggregate chars/s, FPGA single core vs CPU all-core
  4. correctness.png         -- exact-match lines + the by-design punctuation omission
  5. energy_per_million.png  -- ONLY if results/power.csv exists (energy/1M tokens)

power.csv schema (fill in once you have report_power + CPU power), one row per platform:
  platform,clock_hz,power_w,note     e.g.  FPGA fabric,100000000,0.42,report_power dynamic
Run:  pip install matplotlib   then   py ./plot_results.py
"""
import csv
import os
import sys

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit("Missing dependency. Install with:  pip install matplotlib")

HERE = os.path.dirname(os.path.abspath(__file__))
R    = os.path.join(HERE, "results")
FIG  = os.path.join(HERE, "figures")
os.makedirs(FIG, exist_ok=True)

COMP = os.path.join(R, "comparison.csv")
if not os.path.exists(COMP):
    sys.exit("missing results/comparison.csv -- run compare_results.py first")

with open(COMP, encoding="utf-8-sig", newline="") as f:
    rows = sorted(csv.DictReader(f), key=lambda r: int(r["chars"]))

chars        = [int(r["chars"]) for r in rows]
cpu_core     = [float(r["cpu_core_us"]) for r in rows]
cpu_core_min = [float(r["cpu_core_min_us"]) for r in rows]
cpu_core_max = [float(r["cpu_core_max_us"]) for r in rows]
cpu_core_jit = [float(r["cpu_core_jitter_us"]) for r in rows]
cpu_ovh      = [float(r["cpu_ovh_us"]) for r in rows]
fpga_us      = [float(r["fpga_us"]) for r in rows]


def save(fig, name):
    p = os.path.join(FIG, name)
    fig.savefig(p, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print("wrote", os.path.relpath(p, HERE))


# 1. latency vs length -------------------------------------------------------
fig, ax = plt.subplots(figsize=(8, 5))
ax.fill_between(chars, cpu_core_min, cpu_core_max, color="C1", alpha=0.18,
                label="CPU core min-max (jitter)")
ax.plot(chars, cpu_ovh,  "^-", color="C2", ms=4, lw=1, label="CPU full call (median)")
ax.plot(chars, cpu_core, "s-", color="C1", ms=4, lw=1, label="CPU core / Rust (median)")
ax.plot(chars, fpga_us,  "o-", color="C0", ms=4, lw=1.5, label="FPGA fabric (deterministic)")
ax.set_xlabel("input length (characters)")
ax.set_ylabel("latency (microseconds)")
ax.set_yscale("log")
ax.set_title("Tokenization latency vs input length")
ax.grid(True, which="both", alpha=0.3)
ax.legend()
save(fig, "latency_vs_length.png")

# 2. jitter vs length (determinism) ------------------------------------------
fig, ax = plt.subplots(figsize=(8, 5))
ax.scatter(chars, cpu_core_jit, s=22, color="C1", label="CPU core jitter (max - min)")
ax.axhline(0, color="C0", lw=2.5, label="FPGA fabric jitter = 0 (cycle-exact)")
ax.set_xlabel("input length (characters)")
ax.set_ylabel("jitter (microseconds)")
ax.set_yscale("symlog")
ax.set_title("Run-to-run jitter: CPU varies, FPGA is deterministic")
ax.grid(True, which="both", alpha=0.3)
ax.legend()
save(fig, "jitter_vs_length.png")

# 3. throughput (aggregate chars/s) ------------------------------------------
sum_chars = sum(chars)
sum_cyc   = sum(int(r["fpga_cycles"]) for r in rows)
fpga_cps  = sum_chars / (sum_cyc * 1e-8)          # 10 ns/cycle
labels, vals, colors = ["FPGA fabric\n(1 core, 100 MHz)"], [fpga_cps / 1e6], ["C0"]
tp = os.path.join(R, "cpu_throughput.csv")
cpu_threads = "?"
if os.path.exists(tp):
    with open(tp, encoding="utf-8-sig") as f:
        tr = next(csv.DictReader(f))
    cpu_threads = tr["threads"]
    labels.append(f"CPU batched\n({cpu_threads} threads)")
    vals.append(float(tr["chars_per_sec"]) / 1e6)
    colors.append("C1")
fig, ax = plt.subplots(figsize=(6.5, 5))
bars = ax.bar(labels, vals, color=colors, width=0.6)
for b, v in zip(bars, vals):
    ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.2f} M/s",
            ha="center", va="bottom", fontsize=10)
ax.set_ylabel("throughput (million characters / second)")
ax.set_title("Throughput: one FPGA core vs all CPU cores\n"
             "(FPGA is a single instance; the device has headroom to replicate)")
ax.grid(True, axis="y", alpha=0.3)
save(fig, "throughput.png")

# 4. correctness -------------------------------------------------------------
N       = len(rows)
matched = sum(int(r["match"]) for r in rows)
tot_bert  = sum(int(r["bert_tokens"]) for r in rows)
tot_word  = sum(int(r["expected_tokens"]) for r in rows)
tot_punct = sum(int(r["punct_tokens"]) for r in rows)
fig, (axA, axB) = plt.subplots(1, 2, figsize=(11, 4.5))
# left: lines exact vs edge-case
axA.bar(["exact match", "edge-case\nmismatch"], [matched, N - matched],
        color=["C2", "C3"], width=0.55)
axA.text(0, matched, f"{matched}/{N}\n({100*matched/N:.0f}%)", ha="center", va="bottom")
axA.text(1, N - matched, f"{N-matched}", ha="center", va="bottom")
axA.set_ylabel("corpus lines")
axA.set_title("Exact word-token match per line")
axA.grid(True, axis="y", alpha=0.3)
# right: token breakdown (what the FPGA reproduces vs omits by design)
axB.barh(["BERT tokens"], [tot_word], color="C2", label=f"word tokens reproduced ({tot_word})")
axB.barh(["BERT tokens"], [tot_punct], left=[tot_word], color="0.6",
         label=f"punctuation omitted by design ({tot_punct}, {100*tot_punct/tot_bert:.1f}%)")
axB.set_xlabel("tokens")
axB.set_title("Token breakdown across the corpus")
axB.legend(loc="lower center", bbox_to_anchor=(0.5, -0.45))
fig.suptitle("Correctness vs HuggingFace bert-base-uncased")
save(fig, "correctness.png")

# 5. energy: J per 1M tokens AND tokens per Joule (only if power data is present) ----
pw = os.path.join(R, "power.csv")
if os.path.exists(pw):
    # Expecting columns: platform, throughput_tokens_per_sec, power_w
    plats, epm, tpj, is_fpga = [], [], [], []
    with open(pw, encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            try:
                tps = float(r["throughput_tokens_per_sec"]); p = float(r["power_w"])
            except (KeyError, ValueError):
                continue
            name = r["platform"]
            short = "FPGA\nfabric" if "FPGA" in name else \
                    name.split("(")[0].strip().replace("CPU ", "CPU\n", 1)
            plats.append(short)
            epm.append(p / tps * 1e6)        # Joules per 1,000,000 tokens (lower = better)
            tpj.append(tps / p)              # tokens per Joule          (higher = better)
            is_fpga.append("FPGA" in name)
    if plats:
        colors = ["C0" if f else "C1" for f in is_fpga]
        fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 5))
        # left: energy per 1M tokens (lower better)
        b1 = a1.bar(plats, epm, color=colors)
        a1.set_yscale("log")
        a1.set_ylabel("energy per 1,000,000 tokens (Joules)")
        a1.set_title("Energy per 1M tokens  (lower = better)")
        for b, v in zip(b1, epm):
            a1.text(b.get_x() + b.get_width() / 2, v, f"{v:.3g} J", ha="center", va="bottom")
        a1.grid(True, axis="y", which="both", alpha=0.3)
        # right: tokens per Joule (higher better)
        b2 = a2.bar(plats, tpj, color=colors)
        a2.set_yscale("log")
        a2.set_ylabel("tokens per Joule")
        a2.set_title("Tokens per Joule  (higher = better)")
        for b, v in zip(b2, tpj):
            a2.text(b.get_x() + b.get_width() / 2, v, f"{v:,.0f}", ha="center", va="bottom")
        a2.grid(True, axis="y", which="both", alpha=0.3)
        if len(epm) >= 2:
            ratio = max(epm) / min(epm)
            fig.suptitle(f"Energy efficiency: FPGA tokenizer vs CPU  (~{ratio:.0f}x better per token)",
                         fontsize=13)
        save(fig, "energy_per_million.png")
else:
    print("(skipped energy_per_million.png -- create results/power.csv after report_power)")

print(f"\nFigures in {os.path.relpath(FIG, HERE)}/")
