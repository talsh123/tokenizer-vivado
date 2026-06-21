# Stage 5 — Partner evidence index (for Rafi / the book)

Master map of every Stage-5 deliverable → **status**, **where the file is**, **book chapter**.
Status legend: ✅ DONE (committed) · 📝 PRODUCED THIS PASS · 🟡 YOU MUST CAPTURE (Vivado/board) · ⬜ N/A-other-route

All paths are relative to `analysis/` unless noted. Repo: `tokenizer-vivado` (uart), pushed.

---

## P0 — blocking for the book

| # | Deliverable | Status | Location | Book |
|---|---|---|---|---|
| 1 | Raw CSV/log/script for all 6 graphs | ✅ | `results/*.csv` + `*.py` + `figures/*.png` (see §A) | Ch 10 + App F |
| 2 | Energy calculation sheet | 📝 | `evidence/ENERGY_CALCULATION.md` | Ch 10.4 |
| 3 | AXI-timer DMA-latency sweep across lengths | ✅ / 🟡 | `results/fpga_results.csv` (66-pt fabric sweep) + board points 54–72 µs; **wider on-board sweep = optional** (§C) | Ch 10.3.2 / C26 |
| 4 | CPU benchmark script/log + 7435HS + 16-thread | 📝 | `evidence/BENCHMARK_SETUP.md` + `cpu_tokenizer_benchmark.py` + `results/cpu_*.csv` | Ch 10.3–10.4 |
| 5 | Corpus + mismatch list for the 2/66 | 📝 | `evidence/MISMATCH_REPORT.md` + `corpus.txt` | Ch 10.2 |
| 6 | Vivado `report_utilization` | ✅ | `results/utilization_impl.rpt`, `results/utilization_hier.rpt` (LUT 22,511 / FF 26,534 / BRAM 212 / DSP 0) | Ch 10.5 |
| 7 | Vivado `report_timing_summary` + `.xdc` | ✅ | `results/timing_summary.rpt` (WNS −0.374 ns, TNS −0.703, 2 failing eps), `results/Nexys-Video-Master.xdc` | Ch 6.5 / 10.5 |
| 8 | Block design screenshot | ✅ | `figures/block_design.jpg` | Ch 6 / 8 |
| 9 | Address Editor screenshot | ✅ | `figures/address_editor.jpg` | Ch 8 |
| 10 | `tb_axi_dma.v` + xsim PASS transcript | ✅ | source `uart.srcs/sim_1/new/tb_axi_dma.v`; transcript `evidence/tb_axi_dma_transcript.txt` (3/3 PASS) | Ch 9 |

## P1 — strengthens chapters

| # | Deliverable | Status | Location | Book |
|---|---|---|---|---|
| 11 | Waveform: `s_axis_tlast`/`m_axis_tlast`/`TOKEN_COUNT`/S2MM | ✅ | `figures/waveform.jpg` (m_axis_tlast on final token 4667; TOKEN_COUNT read 2→3; m_axis_tready accept) | Ch 7.6.4 / 9 |
| 12 | Full board TCP regression log after DMA | 🟡 | **capture — §C** (PuTTY/telnet log) | Ch 9.5 / 10.2 |
| 13 | Route B Quartus fit/map/sta + .sof/.pof + Icarus vvp | ⬜ | partner's other route — not in this repo | Ch 12 |
| 14 | PNG/SVG exports of all Mermaid diagrams | 🟡 | export from the `.md` Mermaid blocks (§D) | Ch 6–9 / App E |

## P2 — nice to have

| # | Deliverable | Status | Book |
|---|---|---|---|
| 15 | Board setup photo + demo screenshot | 🟡 phone/screenshot | Ch 8/9 appendix |

---

## §A — graph → data → script provenance (P0 #1)

| Figure (`figures/`) | Data (`results/`) | Script |
|---|---|---|
| `latency_vs_length.png` | `comparison.csv` | `plot_results.py` |
| `jitter_vs_length.png` | `comparison.csv` | `plot_results.py` |
| `throughput.png` | `comparison.csv`, `cpu_throughput.csv` | `plot_results.py` |
| `correctness.png` | `comparison.csv` | `plot_results.py` |
| `energy_per_million.png` (2-panel: J/1M + tok/J) | `power.csv` | `plot_results.py` |

`comparison.csv` is built by `compare_results.py` from `cpu_results.csv` (CPU) +
`fpga_results.csv` (sim). `power.csv` holds the two platform rows (FPGA 0.051 W, CPU 30 W).
The 6th "graph" if counted separately is the energy figure's second panel (tokens/Joule).

---

## §B — Vivado / sim captures you must do (open the implemented design)

> Tcl console paths assume the project is open. Save reports under `analysis/results/`.

**B.1 Utilization (P0 #6)**
```tcl
open_run impl_1
report_utilization -file {c:/Users/talsh/.Xilinx/projects/uart/analysis/results/utilization_impl.rpt}
report_utilization -hierarchical -file {c:/Users/talsh/.Xilinx/projects/uart/analysis/results/utilization_hier.rpt}
```
Need: LUT / FF / BRAM / DSP for the tokenizer IP and whole design → Ch 10.5 table.

**B.2 Timing (P0 #7)**
```tcl
report_timing_summary -file {c:/Users/talsh/.Xilinx/projects/uart/analysis/results/timing_summary.rpt}
```
Need: WNS / TNS / Fmax at 100 MHz. (Known WNS ≈ −0.626 ns — report it honestly; note it's a
hold/setup detail on a non-critical path if that's the case.) Also copy the `.xdc` from
`uart.srcs/constrs_1/` into `evidence/` or cite its path.

**B.3 Block design screenshot (P0 #8)** — Open Block Design → fit view → show MicroBlaze,
AXI DMA, SmartConnect, MIG/DDR, tokenizer IP → screenshot → `evidence/figures/block_design.png`.

**B.4 Address Editor (P0 #9)** — Block Design → Address Editor tab → expand MicroBlaze data →
screenshot showing tokenizer `0x44A0_0000`, AXI DMA `0x41E1_0000`, timer, DDR `0x8000_0000`
→ `evidence/figures/address_editor.png`. (These are the exact addresses `echo.c` uses.)

**B.5 tb_axi_dma PASS transcript (P0 #10)** — run `tb_axi_dma` in xsim, copy the console
(the PASS line + TOKEN_COUNT/tlast checks) → `evidence/tb_axi_dma_transcript.txt`.

**B.6 DMA waveform (P1 #11)** — in the `tb_axi_dma` sim, add `s_axis_tlast`, `m_axis_tlast`,
`TOKEN_COUNT`, and the S2MM done/SR signals to the wave; screenshot one transaction →
`evidence/figures/dma_waveform.png`.

---

## §C — Board TCP regression log + on-board latency sweep (P0 #3 wider / P1 #12)

Optional but strong: telnet/PuTTY the board, send corpus lines of **increasing length**,
capture the UART `DMA total: %u us | Tokens: %d` lines → `evidence/board_tcp_regression.txt`.
That turns the 3-point board latency (54–72 µs) into a real sweep matching the sim graph.

---

## §D — Mermaid exports (P1 #14)
Each architecture diagram is a ```mermaid block in the `.md` docs. Export via mermaid.live
or the VS Code Mermaid extension → PNG **and** SVG → `evidence/figures/`. Needed for Word/PDF.

---

## What I produced this pass (📝, committed)
- `evidence/ENERGY_CALCULATION.md` — the ~285×/152× defense sheet (P0 #2)
- `evidence/MISMATCH_REPORT.md` — 64/66 + the 2 decoded failures (P0 #5)
- `evidence/BENCHMARK_SETUP.md` — CPU 7435HS/16-thread + FPGA sim methodology (P0 #4)
- `evidence/EVIDENCE_INDEX.md` — this file

## What only you can produce (🟡): P0 #6,7,8,9,10 ; P1 #11,12,14 ; P2 #15
Everything in §B/§C/§D. Save screenshots/reports under `analysis/evidence/figures/` and
`analysis/results/`, then commit + push.
