# Continuation prompt — FPGA BERT WordPiece Tokenizer

Paste this into a new session (or hand it to another engineer). It is self-contained: state, open
issues, last work, next steps, and everything needed to continue.

---

## 1. Role & project

You are continuing a final-year digital-design project: a **hardware BERT WordPiece tokenizer on a
Nexys Video FPGA** (Xilinx Artix-7). ASCII text arrives over TCP (lwIP echo server, port 7) into a
MicroBlaze SoC, is streamed through a custom RTL tokenizer core over **AXI DMA / AXI4-Stream** (with
AXI4-Lite for control/status), and the BERT `bert-base-uncased` token IDs are returned to the client.
Token IDs must match HuggingFace `bert-base-uncased` for the supported ASCII stream. Punctuation is
dropped **by design**; ASCII-only; no `[CLS]`/`[SEP]`.

Pipeline: `pre_tokenizer.v` (lowercase, char→10-bit index, word-boundary detect) → `trie_engine.v`
(greedy longest-match over two CSR tries — root 56,719 nodes/56,718 edges, continuation 7,864/7,863;
10-state FSM, binary search per node, 32-char backtracking buffer) → `tokenizer_axi_lite.v` (FIFOs
256×8 in / 256×16 out, AXI4-Lite regs, AXI4-Stream `s_axis`/`m_axis`, `TOKEN_COUNT` reg). Vocabulary
(30,522) is compressed offline to CSR `.mem` files loaded via `$readmemh`.

## 2. The three repositories

| Repo | Path | Remote | Unpushed (2026-06-22) |
|---|---|---|---|
| **Vivado / RTL** (uart) | `C:\Users\talsh\.Xilinx\projects\uart` | tokenizer-vivado | **9** commits |
| **Vitis firmware** | `C:\Users\talsh\Vitis\final_project_eth_nexys_video` | tokenizer-vitis | **2** (`a403add`, `7b400dc`) |
| **CSR Python generator** | `…\OneDrive\…\BERT\flat_trie_compression` | tokenizer-csr | in sync |

**Pushing:** the AI shell has no SSH key — the **user pushes** from their own terminal
(`git -C <repo> push`). Commit locally; ask the user to push.

## 3. ⚠️ LIVE BLOCKER (do this first): get the #2 fix onto silicon

The **#2 correctness fix is sim-verified 66/66 but the board still runs the pre-fix bitstream**
(returns `along` for `summarize a long`, `tvocab` for `vocab t vocab`). Two build problems were hit:

1. **Auto-incremental synthesis** (RESOLVED): `.xpr` had `AutoIncrementalCheckpoint="true"` with a
   reference checkpoint whose chain traced to a pre-#2-fix build, so every rebuild reused the stale
   tokenizer partition. Deleted `uart.srcs/utils_1/imports/synth_1/design_1_wrapper.dcp` and you must
   keep incremental OFF: `set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]`.

2. **Tri-Mode Ethernet MAC license** (THE LIVE BLOCKER): the full (non-incremental) synthesis
   re-processes `axi_ethernet_0`; `write_bitstream` fails
   `[Common 17-69] tri_mode_eth_mac requires > Design Linking license`. The user is obtaining the free
   **hardware-evaluation** license (AMD Product Licensing → "Add Evaluation and No Charge IP Cores" →
   search "ethernet" → `LogiCORE, Tri-Mode Ethernet MAC Evaluation License` → Add → Generate
   Node-Locked License → download `.lic` → Vivado **Help → Manage License → Load License**). Eval =
   **time-limited** bitstream (Ethernet stops after a few hours; reprogram to resume — fine for a demo).

### Build → verify → flash procedure (after the license is loaded)
```tcl
reset_run impl_1
reset_run synth_1
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
reset_target all  [get_files design_1.bd]
generate_target all [get_files design_1.bd]   ;# do NOT interrupt (an interrupt caused
                                               ;# '[Common 17-354] Could not open C for writing')
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
```
**Verify the fix is actually in the bitstream BEFORE flashing** (reliable — do NOT grep `uart.runs`,
the `.rpx` reports are binary and false-match):
```tcl
open_run impl_1
puts "word_done_count: [llength [get_cells -hierarchical -filter {NAME =~ *word_done_count*}]]"  ;# must be > 0
puts "word_done_pending: [llength [get_cells -hierarchical -filter {NAME =~ *word_done_pending*}]]" ;# must be 0
```
Then export `.xsa` → Vitis re-read → **if the BSP regenerated, re-apply the PHY patches**:
`powershell -ExecutionPolicy Bypass -File lwip_echo_server/src/phy_patch/apply_phy_patch.ps1` → rebuild
the app → flash. **Flash the fresh bitstream** — `launch.json` points at
`uart.runs/impl_1/design_1_wrapper.bit` (the `_ide/bitstream` cache footgun was already handled).

### On-board reverify (the finish line)
Telnet port 7 + serial @115200. Expected (HuggingFace, punctuation dropped, lowercase):
- Golden: `hello`→`7592`; `hello hardware`→`7592 8051`; `embedding`→`7861 8270 4667`;
  `the quick brown fox jumps over the lazy dog`→`1996 4248 2829 4419 14523 2058 1996 13971 3899`;
  `2024`→`16798 2549`; `abc123`→`5925 12521 2509`.
- **#2 fix proof (the whole point):** `summarize a long`→`7680 7849 4697 1037 2146`;
  `vocab t vocab`→`29536 3540 2497 1056 29536 3540 2497`. If these are correct (1037/1056 standing
  alone, not merged) → **66/66 on silicon** and the hardening pass is done.
- Robustness (#7): send an empty / punctuation-only line → `boundary-only, skipped`, server keeps
  serving (no hang).

## 4. Open issues (full list)

| # | Item | State | Next |
|---|---|---|---|
| **#2** | 1-char-word merge | RTL fixed, **sim 66/66**, NOT on silicon | the §3 build (live) |
| **#7** | zero-token DMA TLAST | `echo.c` `tokenizer_dma_recover()` + `has_word` guard (committed) | on-board reverify after reflash |
| **#8** | cache invalidate `ntok×2` | `echo.c` (committed) | on-board reverify |
| **#10** | durable PHY patch | `phy_patch/*.golden` + `apply_phy_patch.ps1` (committed) | run script after BSP regen |
| **#1** | WNS −0.374 ns | **documented benign** (ASYNC_REG CDC syncs inside the AMD Ethernet MAC; user logic +0.6 ns) | none, unless you want WNS≥0 via a CDC false_path |
| **#9** | `init_calib_complete` not in reset | **deferred** | optional: `AND(clk_wiz_1/locked, init_calib_complete) → rst_clk_wiz_1_100M/dcm_locked` (NOT the MIG reset block); on-board boot test |
| **Book** | `final_project_book.pdf` corrections | audited | see §6 |
| Push | uart 9 + vitis 2 unpushed | — | user pushes |

Parked/optional (not blocking): cross-segment word reassembly in DMA path; `fast_path` for short
inputs; direct first-char table; multi-core tokenizer replication; full punctuation handling. See
`OPTIMIZATION_OPTIONS.md`.

## 5. Last work done (this session)
- **#2 fix** in `trie_engine.v`: `word_done_pending` (1-bit) → `word_done_count` (2-bit saturating
  counter, `+1` per boundary, `−1` per finalize via `bnd_consume`). New TB `tb_word_boundary.v` (8/8).
  Full corpus 64/66 → **66/66** (sim). Committed (`03f00c9`).
- **Vitis #7/#8/#10** in `echo.c` + `phy_patch/` (`a403add`, `7b400dc`).
- **#1** characterized benign, **#9** deferred (decisions documented).
- Built the **evidence pack** (`analysis/evidence/`: ENERGY_CALCULATION, MISMATCH_REPORT,
  BENCHMARK_SETUP, EVIDENCE_INDEX, tb_axi_dma_transcript) + reports
  (`analysis/results/utilization_impl.rpt`, `timing_summary.rpt`, `Nexys-Video-Master.xdc`) + figures
  (`block_design.jpg`, `address_editor.jpg`, `waveform.jpg`).
- Tooling: `analysis/gen_reports.tcl` (utilization+timing+xdc), `analysis/run_all_tbs.tcl` (run all 12
  testbenches; `xsim.simulate.runtime=0` so `run all` isn't doubled).
- Debugged the **stale-bitstream saga**: incremental synthesis (fixed) → TEMAC license (live).
- **Audited the report book** (§6).
- Updated all docs (JOURNAL, HANDOFF, CODE_REVIEW, OPTIMIZATION_OPTIONS, H1_VERIFICATION).

## 6. Book (`final_project_book.pdf`) corrections to make
- **Two reversed token vectors** (root piece must be FIRST): §9.5.1 + Table 10.2 — `tokenization`
  is `19204 3989` (book has `3989 19204`); `internationalization` is `2248 3989` (book has `3989 2248`).
- Book describes the **pre-#2-fix** state: correctness **64/66 (~97%)**, "2 edge-case mismatches"
  (Fig 10.1, Tables 10.1/10.5, Appendix F C21), boundary mechanism `word_done_pending` (Table 7.3,
  §7.5.1, the `busy` snippet in §7.6.2). **Once #2 is on silicon (66/66), update** to 66/66 / 100% /
  0 mismatches and `word_done_pending`→`word_done_count`, add the #2 fix to §7.5 + Appendix F.3.
- **`file:line` citations are stale** after the #2 fix shifted `trie_engine.v` (e.g. busy
  189-203→204-214, char_buf 152-170→158-165, H2 guard 451-464→459-465) and `echo.c` after #7/#8.
  Re-sync to the final commit.
- **Now-available artifacts** the book marks "pending/not saved": utilization (22,511 LUT / 26,534 FF /
  212 BRAM / 0 DSP), timing (WNS −0.374 ns), the xdc, the 3 screenshots/waveform, the tb_axi_dma
  transcript — all in `analysis/`.
- Everything else verified correct (constants, register map, STATUS packing, energy/throughput numbers,
  9/11 vectors, 2,925/462/13.6% punctuation breakdown). Route B (DE10-Lite/Quartus/Icarus) is the
  partner's separate route — not independently verified here.

## 7. Hard constraints (do not violate)
- **No mention of "Claude"** in commit messages.
- **Verification is always done by the user** (program the board, run telnet, confirm). Don't claim
  on-silicon results you haven't been shown.
- **Vivado only** (no ModelSim). Sim = Vivado xsim.
- **Re-apply the RTL8211E PHY patches after every BSP regen / `.xsa` re-read** (they get wiped):
  `xadapter.c` (first_link/hardcode-100) and `xaxiemacif_physpeed.c` (Realtek `0x001c` branch). The
  durable mechanism is `lwip_echo_server/src/phy_patch/` + `apply_phy_patch.ps1` (canonical copies are
  `*.c.golden` so the IDE can't auto-compile them).
- Don't modify the **generated IP wrapper** (`design_1_wrapper.v`). Don't alter the canonical `.mem`
  files. No internal problem IDs (H1/M2/…) in synthesizable RTL comments.
- After editing tokenizer RTL: **disable incremental synthesis** and verify `word_done_count` in
  `impl_1` before flashing (see §3).

## 8. Key references
- Docs: `JOURNAL.md` (append-only running log — only the latest sections are authoritative),
  `HANDOFF.md` (top status block), `CODE_REVIEW.md` (§6 H1–L3 table, §7 R2 architecture, §8 known
  limitations, §9 hardening pass), `OPTIMIZATION_OPTIONS.md`, `H1_VERIFICATION.md`,
  `analysis/evidence/EVIDENCE_INDEX.md` (partner deliverable map).
- Memories (persistent): `vitis-bsp-phy-patches`, `vitis-stale-bitstream-launch`,
  `vivado-module-ref-stale-synth` (the latter now correctly attributes the bug to **incremental
  synthesis** + notes the `get_cells` verification and the TEMAC-license consequence of a full build).
- Testbenches (`uart.srcs/sim_1/new/`): `tb_word_boundary.v` (#2), `tb_axi_dma.v` (DMA/TLAST/TOKEN_COUNT),
  `tb_axi_pipeline.v` (P1/M4), `tb_h1_h2_m1.v`, `tb_m2_overflow.v`, plus the originals.
