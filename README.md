# FPGA BERT WordPiece Tokenizer

A **hardware implementation of the BERT WordPiece tokenizer**, running on a Nexys Video
FPGA. You send plain ASCII text to the board over the network, and it streams back the
exact **`bert-base-uncased` token IDs** — computed entirely in custom digital logic, not
software.

> **Status: complete and verified on silicon — 100 % (66/66) on the evaluation corpus.**
> Every token ID matches HuggingFace `bert-base-uncased` for the supported ASCII input.

This is a final-year digital-design project. The goal was to take a real, non-trivial NLP
pre-processing step (the tokenizer that sits in front of every BERT model) and prove it can
be done in hardware — correctly, and faster than the CPU path it replaces.

---

## Table of contents

1. [What it does](#what-it-does)
2. [How it works (the pipeline)](#how-it-works-the-pipeline)
3. [System architecture](#system-architecture)
4. [Repository layout](#repository-layout)
5. [The three repositories](#the-three-repositories)
6. [Register map & interfaces](#register-map--interfaces)
7. [Building the hardware (Vivado)](#building-the-hardware-vivado)
8. [Building & flashing the firmware (Vitis)](#building--flashing-the-firmware-vitis)
9. [Using it](#using-it)
10. [Testing & verification](#testing--verification)
11. [Results](#results)
12. [Known limitations (by design)](#known-limitations-by-design)
13. [Vocabulary generation](#vocabulary-generation)
14. [Documentation index](#documentation-index)

---

## What it does

BERT (and most transformer models) don't read raw text — they read **token IDs**. Turning
text into those IDs is the job of the **WordPiece tokenizer**: it greedily breaks each word
into the longest sub-word pieces that exist in a fixed 30,522-entry vocabulary, and maps
each piece to a number.

This project does that in hardware:

```
  "hello hardware"   ──►  [ FPGA tokenizer ]  ──►   7592 8051
  "embedding"        ──►  [ FPGA tokenizer ]  ──►   7861 8270 4667
  "the quick brown fox jumps over the lazy dog"
                     ──►  [ FPGA tokenizer ]  ──►   1996 4248 2829 4419 14523 2058 1996 13971 3899
```

Text arrives over **TCP** (an lwIP echo-style server on port 7), is streamed through a custom
RTL tokenizer core via **AXI DMA**, and the resulting token IDs are sent back to the client.

**Design choices to be aware of** (see [Known limitations](#known-limitations-by-design)):
ASCII only; input is lower-cased; punctuation is treated as a word boundary and **dropped**
(no standalone punctuation tokens); no `[CLS]`/`[SEP]` framing tokens are added.

---

## How it works (the pipeline)

The tokenizer core is three custom Verilog modules wired in series. The clever part is the
**trie engine**: instead of storing the vocabulary as strings, the 30,522 words are compiled
offline into two **compressed-sparse-row (CSR) tries** (a prefix tree for word-initial pieces
and one for continuation pieces), and the hardware walks them with a binary search per node.

```
   raw ASCII bytes
        │
        ▼
┌─────────────────────┐   pre_tokenizer.v
│   PRE-TOKENIZER      │   • lower-cases A–Z
│                      │   • maps each char → 10-bit alphabet index
│                      │   • detects word boundaries (non a-z0-9)
└─────────┬───────────┘
          │  10-bit char index + word-done pulse
          ▼
┌─────────────────────┐   trie_engine.v   ← the core algorithm
│   TRIE ENGINE        │   • greedy longest-match WordPiece
│                      │   • 10-state FSM, binary search per trie node
│                      │   • 32-char backtracking buffer for re-scan
│                      │   • root trie: 56,719 nodes / 56,718 edges
│                      │   • continuation trie: 7,864 / 7,863
│                      │   • emits [UNK] (id 100) when nothing matches
└─────────┬───────────┘
          │  16-bit BERT token IDs
          ▼
┌─────────────────────┐   tokenizer_axi_lite.v
│   AXI WRAPPER        │   • input FIFO  (256 × 8-bit)
│                      │   • output FIFO (256 × 16-bit)
│                      │   • AXI4-Lite control/status registers
│                      │   • AXI4-Stream s_axis / m_axis for DMA
│                      │   • TOKEN_COUNT register
└─────────────────────┘
```

`top_tokenizer.v` is a thin wrapper that connects the pre-tokenizer and trie engine and
exposes a single `pipeline_busy` signal.

The vocabulary is loaded into on-chip BRAM at synthesis time from `.mem` files
(`$readmemh`), so there is no run-time vocabulary loading.

---

## System architecture

The tokenizer core is one IP block inside a MicroBlaze soft-processor SoC built in Vivado's
block design:

```
        ┌────────────────────────── Nexys Video (Artix-7 XC7A200T) ──────────────────────────┐
        │                                                                                      │
  PC ───┤  RJ-45 ── AXI Ethernet ── lwIP ── MicroBlaze ── AXI DMA ── [ tokenizer core ] ──┐    │
 (TCP   │                              │                                              ▲    │    │
 :7)    │                              └────── AXI4-Lite (control/status) ────────────┘    │    │
        │                                                                                  │    │
        │                              MIG DDR3   ·   UART @115200 (debug console)         │    │
        └──────────────────────────────────────────────────────────────────────────────────────┘
```

- **MicroBlaze** runs the lwIP TCP server (`echo.c` in the Vitis project).
- **AXI DMA** moves bytes into the tokenizer and tokens back out with no per-byte CPU work
  (the "R2" datapath — ~14× faster than byte-by-byte AXI-Lite polling).
- **AXI4-Lite** is kept for control, status polling, and as a fallback datapath.
- The clock is **100 MHz**; reset is active-high inside the core (converted from the
  active-low AXI reset).

---

## Repository layout

```
uart/
├── README.md                  ← you are here
├── uart.xpr                   Vivado project file
├── design_1_wrapper.xsa       exported hardware handoff (for Vitis)
│
├── uart.srcs/sources_1/new/   ★ the custom RTL (the heart of the project)
│   ├── pre_tokenizer.v        lower-case + char map + boundary detect
│   ├── trie_engine.v          greedy WordPiece trie walker (the core)
│   ├── tokenizer_axi_lite.v   FIFOs + AXI4-Lite + AXI4-Stream wrapper
│   └── top_tokenizer.v        wiring of the two stages
│
├── uart.srcs/sim_1/new/       12 testbenches (see Testing)
│
├── uart.gen/ , uart.runs/     Vivado-generated IP, synth & impl outputs
│
└── analysis/                  measurement, evidence & tooling
    ├── *.py                   CPU benchmark, plotting, corpus tooling
    ├── run_all_tbs.tcl        one-action run of all 12 testbenches
    ├── gen_reports.tcl        dump utilization + timing + xdc
    ├── corpus.txt             66-line evaluation corpus
    ├── results/               CSVs + utilization/timing reports
    ├── figures/               graphs + block-design/waveform screenshots
    └── evidence/              defense write-ups (correctness, energy, benchmark)
```

The `.mem` files that hold the compiled vocabulary live alongside the RTL and are loaded by
`$readmemh` at synthesis: `char_to_index_map.mem`, `root_csr_*.mem`, `cont_csr_*.mem`,
`*_is_terminal.mem`, `*_token_ids.mem`.

---

## The three repositories

This project spans three Git repositories:

| Repo | What it holds | This repo? |
|------|---------------|------------|
| **uart** (this one) | Vivado project + custom RTL + analysis | ✅ |
| **Vitis firmware** (`final_project_eth_nexys_video`) | MicroBlaze app: lwIP TCP server, DMA driver, PHY patches (`echo.c`) | separate |
| **CSR generator** (`flat_trie_compression`) | Python that compiles the BERT vocab → the `.mem` CSR trie files | separate |

---

## Register map & interfaces

The tokenizer core is mapped at AXI base address **`0x44A00000`**. Four 32-bit AXI4-Lite
registers (address bits `[3:2]` select the register):

| Offset | Name | Access | Meaning |
|--------|------|--------|---------|
| `0x00` | `TX_DATA` | write | push one ASCII byte (low 8 bits) into the input FIFO |
| `0x04` | `RX_DATA` | read | pop one 16-bit token ID from the output FIFO (zero-extended) |
| `0x08` | `STATUS` | read / write | status bits (below); **write** clears the overflow flag |
| `0x0C` | `TOKEN_COUNT` | read / write | tokens produced since last clear; **write** clears the counter |

**STATUS bits (read):**

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | `can_write` | input FIFO has space (safe to write `TX_DATA`) |
| 1 | `has_token` | output FIFO has a token to read |
| 2 | `overflow` | a token was dropped because the output FIFO was full (sticky) |
| 3 | `pipeline_busy` | something is still in flight anywhere in the pipeline/FIFOs |

**AXI4-Stream (DMA datapath):** `s_axis` (8-bit, bytes in) and `m_axis` (16-bit, tokens out),
with `tlast` marking the final byte/token of a transfer. The firmware reads `TOKEN_COUNT`
after a DMA transfer because simple-mode S2MM does not report the received length.

---

## Building the hardware (Vivado)

Built and verified with **Vivado 2025.2**. Open `uart.xpr`.

> ⚠️ **Two gotchas that have each cost a full build cycle — read these first.**

**1. The Tri-Mode Ethernet MAC license.** The AXI Ethernet IP wraps Xilinx's TEMAC, which
needs a license to *generate a bitstream*. If `write_bitstream` fails with
`[Common 17-69] tri_mode_eth_mac requires > Design Linking license`, load the free
**Tri-Mode Ethernet MAC Hardware-Evaluation** license (AMD Product Licensing → *Add
Evaluation and No-Charge IP Cores* → search "ethernet" → add the eval license → node-locked
`.lic` → Vivado **Help → Manage License → Load License**), then **restart Vivado**. The eval
bitstream is time-limited (Ethernet stops after a few hours; reprogram to resume — fine for a
demo). Confirm via **Help → Manage License → View License Status** (there is no Tcl
`get_license_status` command). The license's *Version Limit* must be ≥ your Vivado release.

**2. Keep incremental synthesis OFF after editing the tokenizer RTL.** Auto-incremental
synthesis can reuse a stale tokenizer partition, so the bitstream silently keeps old logic
even though source and simulation look fixed. Always:

```tcl
reset_run impl_1
reset_run synth_1
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
reset_target  all [get_files design_1.bd]
generate_target all [get_files design_1.bd]   ;# do NOT interrupt this
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
```

**Verify the build before flashing** (reliable — do *not* grep the `.runs` reports; the
`.rpx` files are binary and false-match):

```tcl
open_run impl_1
puts "word_done_count:   [llength [get_cells -hierarchical -filter {NAME =~ *word_done_count*}]]"   ;# must be > 0
puts "word_done_pending: [llength [get_cells -hierarchical -filter {NAME =~ *word_done_pending*}]]"  ;# must be 0
```

Then export the hardware: `write_hw_platform -fixed -include_bit -force -file design_1_wrapper.xsa`.

---

## Building & flashing the firmware (Vitis)

1. In Vitis, point the platform at the freshly exported `design_1_wrapper.xsa`
   (**Update Hardware Specification**) and rebuild the platform/BSP.
2. ⚠️ **Re-apply the PHY patches if the BSP regenerated.** Re-reading the `.xsa` wipes the
   RTL8211E PHY edits in `xadapter.c` / `xaxiemacif_physpeed.c`. Restore them with the
   durable script in the Vitis repo:
   `powershell -ExecutionPolicy Bypass -File lwip_echo_server/src/phy_patch/apply_phy_patch.ps1`
   then rebuild the app. Without this, Ethernet won't link.
3. Program the FPGA and run the app (flash the fresh `uart.runs/impl_1/design_1_wrapper.bit`).

---

## Using it

1. Connect the board's RJ-45 and open the serial console **@115200** to watch boot/debug.
2. The board takes its IP via DHCP, falling back to **`192.168.1.10`** after a timeout.
3. Connect a TCP client to **port 7** and send a line of text:

```
$ telnet 192.168.1.10 7
hello hardware
7592 8051
embedding
7861 8270 4667
```

Punctuation-only or empty lines are reported on the console as `boundary-only, skipped` and
the server keeps serving.

---

## Testing & verification

**Simulation (Vivado xsim).** Twelve testbenches in `uart.srcs/sim_1/new/`. Run them all in
one action:

```tcl
source analysis/run_all_tbs.tcl   ;# PASS/FAIL summary across all 12 TBs
```

Highlights: `tb_word_boundary` (the 1-char-word boundary cases), `tb_axi_dma`
(DMA / `tlast` / `TOKEN_COUNT`), `tb_axi_pipeline` (valid/ready flow control),
`tb_trie_engine`, `tb_pre_tokenizer`, plus overflow and corpus-performance benches.

**On silicon.** The design has been verified on the board over TCP. The decisive cases
(1-character word that follows a multi-piece word — the bug that was the final fix):

```
summarize a long   →  7680 7849 4697 1037 2146          (1037 "a" stands alone)
vocab t vocab      →  29536 3540 2497 1056 29536 3540 2497   (1056 "t" stands alone)
```

**Correctness measurement.** `analysis/compare_results.py` compares the FPGA output against
HuggingFace over the 66-line corpus; `analysis/inspect_mismatch.py` decodes any mismatches.

---

## Results

Measured on the Nexys Video (Artix-7 XC7A200T) at 100 MHz:

| Metric | Value |
|--------|-------|
| **Correctness** | **100 % (66/66)** exact match vs HuggingFace `bert-base-uncased` |
| LUTs | 22,511 |
| Flip-flops | 26,534 |
| BRAM | 212 |
| DSP | 0 |
| DMA round-trip latency | ~54–72 µs (flat across input length) |
| Speedup vs AXI-Lite byte polling | ~14× |
| Worst negative slack (WNS) | −0.374 ns (see limitations) |

Full reports and graphs are in `analysis/results/` and `analysis/figures/`; the supporting
write-ups (correctness, energy, benchmark method) are in `analysis/evidence/`.

---

## Known limitations (by design)

These are deliberate scope decisions, documented here so they aren't mistaken for bugs:

- **Punctuation is dropped.** Any non-`[a-z0-9]` byte is a word boundary; no standalone
  punctuation token is emitted (BERT emits one per mark). This accounts for ~13.6 % of
  BERT's tokens across the corpus — it is the entire reason FPGA output differs from
  HuggingFace on punctuated text, and it is excluded from the 66/66 match count.
- **ASCII only.** Non-Latin / accented / emoji input is unsupported (BERT normalizes
  Unicode; the hardware char map does not).
- **Lower-cased; no `[CLS]`/`[SEP]`.** Matches `bert-base-uncased` word-piece IDs only.
- **Fixed vocabulary in BRAM.** Changing the vocabulary means re-running the CSR generator
  and re-synthesizing.
- **Timing does not fully close:** WNS −0.374 ns on 2 of 87,343 endpoints. Both failing
  paths are CDC reset synchronizers *inside the AMD Ethernet MAC* (vendor IP), not user
  logic — all custom logic meets timing with positive slack, and the board runs correctly.
  Formal closure is left as future work.

Optional/future ideas (not blocking) are tracked in `OPTIMIZATION_OPTIONS.md`.

---

## Vocabulary generation

The 30,522-entry `bert-base-uncased` vocabulary is compiled **offline** into the CSR trie
`.mem` files by the Python generator in the separate `flat_trie_compression` repo. It emits
the eight `.mem` files the RTL loads via `$readmemh`. To change the vocabulary you re-run the
generator and re-synthesize; nothing about the run-time datapath changes.

---

## Documentation index

This repo is heavily documented. Start with whichever fits your need:

| Document | What's in it |
|----------|--------------|
| **README.md** | this overview |
| `HANDOFF.md` | current status block + full project handoff (read the top first) |
| `JOURNAL.md` | append-only engineering log — every problem, diagnosis, fix, and verification |
| `CODE_REVIEW.md` | the code-review findings (H1–L3), the DMA datapath rationale, and the known-limitations triage |
| `CONTINUATION_PROMPT.md` | self-contained brief to resume the project in a fresh session |
| `H1_VERIFICATION.md` | deep-dive on the trie greedy-match corner cases and how they were verified |
| `OPTIMIZATION_OPTIONS.md` | what's been optimized and what optional work remains |
| `analysis/evidence/EVIDENCE_INDEX.md` | map of every deliverable → file → report chapter |

> Note: `JOURNAL.md` is append-only — earlier entries reflect what was true when written; the
> latest sections (and the top of `HANDOFF.md`) are the authoritative current state.
