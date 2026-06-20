# Continuation prompt (RTFC) — FPGA WordPiece Tokenizer

Paste this into the new chat, or just tell the new chat: "read HANDOFF.md and continue."
(RTFC = Role · Task · Format · Context.)

---

## ⭐ CURRENT STATUS — 2026-06-20 (read this first; the RTFC below is the original, now stale)

**The entire code review is DONE and VERIFIED ON SILICON — H1, H2, M1, M2, M3, M4, P1, L1, L2, L3 —
plus the embed-class boundary fix and two synthesis-warning cleanups.** Full per-problem record with
verification evidence is in `JOURNAL.md`. Headlines:

- **RTL** (`trie_engine.v`, `pre_tokenizer.v`, `tokenizer_axi_lite.v`): H1/H2/M1 (trie greedy-match
  corner cases), M2 (output-FIFO overflow detect, STATUS bit 2), P1 (pure valid/ready flow control +
  trie input skid + boundary char capture — closes the wasted-handshake-cycles issue), M4 RTL
  (`pipeline_busy` STATUS bit 3), L3 (AXI read `read_addr_serviced` gate), plus the char_buf and
  tok_word_busy synthesis-warning cleanups.
- **Firmware** `echo.c`: M3 (raw-byte forwarding, no synthetic boundary) + M4 (drain-on-
  `pipeline_busy`, boundary-aware final drain — the blind ~500 µs delay is gone).
- **Memory generator** `vocab_parser.py` (in `...\OneDrive\...\BERT\flat_trie_compression`): L1
  (token-id `.mem` written 4-hex to match the 16-bit register).
- **Verification:** `tb_axi_pipeline` green (slow-cadence + new digit cases included); full xsim suite
  passes; **on-board over TCP every known vector is correct** and `2024`→`16798 2549`,
  `abc123`→`5925 12521 2509` match sim exactly with no `[UNK]`. Timing closes clean; the 32 char_buf
  and the token-id width synth warnings are gone.

**The embed `[UNK]` "open issue" from the previous handoff is RESOLVED — and it was never an RTL
bug.** The board was running a STALE bitstream: the Vitis run configuration programs a cached
`lwip_echo_server/_ide/bitstream/design_1_wrapper.bit` (it was a month old) while loading a fresh
ELF. **Lesson for next time: when on-board behavior contradicts a clean xsim run, suspect the
programmed bitstream first** — point the Vitis launch config at `uart.runs/impl_1/design_1_wrapper.bit`.

**BSP PHY patches — RE-APPLY AFTER EVERY BSP REGEN (a `.xsa` re-read wipes them):** `xadapter.c`
(`axieth_link_status` first_link/hardcode-100) and `xaxiemacif_physpeed.c` (`get_IEEE_phy_speed`
Realtek `0x001c` branch). Confirm before every board build.

---

## 🔜 OPEN ITEMS — handoff to Rafi

**MUST DO (the one outstanding must — start here): DMA instead of byte-by-byte AXI-Lite polling.**
This is optimization **R2** in `OPTIMIZATION_OPTIONS.md`. Now that M4 removed the blind delay, the
dominant on-board cost is the per-byte MMIO loop: the MicroBlaze spends ~50–100 cycles of software
overhead per byte in `tok_send_byte()` (poll STATUS, write TX_DATA), so a 43-char line takes ~1.1 ms
even though the fabric tokenizes in ~10 µs. Replace the byte-banging with an **AXI-Stream** interface
on the tokenizer IP + an **AXI DMA** (or AXI4 burst) so input bytes stream in and tokens stream out
at ~1/clock with no per-element CPU involvement. Scope: block-design change (add DMA + AXI-Stream
ports on the IP), `echo.c` rewrite (DMA descriptors instead of the send/drain loops), and a full
re-verify against the HuggingFace golden vectors. Detail + the output-regression checklist are in
`OPTIMIZATION_OPTIONS.md` (R2, with F2/F3 as related smaller wins).

**OPTIONAL — NOT required for the final report (do only if time allows):**
- **Connect `init_calib_complete`** in the Vivado block design (currently floating). Wiring it in —
  e.g. gating the processor/system reset — prevents the CPU touching DDR3 before the MIG finishes
  calibration. Real robustness fix, BD-level.
- **`tb_perf_measurement` Test 2 = 16 tokens vs 15** — a simulation-only timing artifact (hardware
  gives the correct 15). Either fix the TB timing or document it explicitly as known sim-only.
- **Elegant RTL8211E PHY bring-up** — the BSP patches are the pragmatic fix; a proper fix implements
  the full RTL8211E auto-negotiation register sequence so the stock-BSP-vs-RTL8211E mismatch is
  handled cleanly. Future work / report discussion only.
- **Relocate the 9 `.mem` files out of `C:/Users/talsh/Downloads/`** into the project tree. The
  `.xpr` sources them from `$PPRDIR/../../../Downloads/*.mem` — functional but fragile (a cleared
  Downloads folder breaks the build). Recommended before final submission.
- Cosmetic: remove the `===== TEMP DEBUG PROBE =====` block in `tb_axi_pipeline.v` for the final
  clean version (kept for now; harmless).

**Vivado/Vitis gotchas (still apply):** the editor buffer can overwrite disk on sim launch and xsim
reuses stale compiled snapshots — **Reset** the sim/run to force a real recompile, and close a file
in the Vivado editor before editing it externally. After any RTL change: regenerate the bitstream,
re-export the `.xsa`, AND re-point the Vitis launch config at the fresh
`impl_1/design_1_wrapper.bit` before programming (re-applying the BSP PHY patches after the BSP regen).

---

## ROLE
You are an experienced FPGA / digital-design and embedded-firmware engineer taking
over an in-progress hardening + optimization effort on a hardware **BERT WordPiece
tokenizer**. You think in clock cycles, FSM states, BRAM ports, and AXI handshakes;
you write synthesizable Verilog and MicroBlaze C; you work **one problem at a time**
and keep an engineering journal for the user's final report (the user is a student;
their partner and professor will read the code and journal).

## TASK
Continue the work.

**Immediate step:** the user is re-running `tb_axi_pipeline` in Vivado after a fix.
Interpret that transcript first.
- If it prints `AXI PIPELINE TESTS PASSED`: mark **P1** and **M4** verified in
  `JOURNAL.md`, then move to the next pending item.
- If it fails: the TB now prints the actual token IDs per test and flushes leftovers
  between tests, so use the printed values to tell apart (a) a remaining
  `pipeline_busy` timing issue from (b) a real tokenization regression in the **P1**
  pre-tokenizer redesign (a duplicated/lost character shows as specific wrong IDs),
  and fix it.

Then continue the remaining items (see Context → PENDING). For every new problem:
give the user a short plain-language **background + which engineering field it
belongs to**, apply a **surgical** fix, add a `JOURNAL.md` entry, and (for RTL)
write/extend a self-checking testbench.

## FORMAT
- Per problem: (1) plain background + engineering discipline; (2) the fix as
  minimal RTL/C edits; (3) a `JOURNAL.md` entry (engineering field, background,
  defect, fix, verification plan, status); (4) a Vivado/board verification plan
  (+ testbench if RTL).
- Be concise; recommend a path, don't over-survey.
- **Verification is ALWAYS done by the user** — Vivado xsim for RTL, board + TCP
  (telnet/netcat to port 7) for firmware. You author tests and instructions; the
  user runs them and pastes results. After each result, update the journal status.

## CONTEXT

**Working dir:** `c:\Users\ENTEL\FPGA tal` (NOT a git repo). Three sub-projects:
- `tokenizer-vivado/` — the RTL. Custom IP `tokenizer_axi_lite` wraps
  `top_tokenizer` → `pre_tokenizer` + `trie_engine`. Hand-written sources in
  `uart.srcs/sources_1/new/`, testbenches in `uart.srcs/sim_1/new/`.
- `tokenizer-csr/` — Python `vocab_parser.py` builds the dual CSR tries and emits
  the `.mem` files from `vocab.txt` (bert-base-uncased, 30,522 tokens).
- `tokenizer-vitis/` — MicroBlaze firmware `lwip_echo_server/src/echo.c`: a TCP
  server on port 7 that streams text to the IP and returns token IDs.

**READ THESE FIRST (source of truth, in the working dir):**
- `JOURNAL.md` — full per-problem record (every fix, with verification + status).
- `CODE_REVIEW.md` — the original findings (H1, H2, M1–M4, L1–L3).
- `OPTIMIZATION_OPTIONS.md` — speed/efficiency options (F1 done; A1, A2, A3, C1,
  D1, R1, R2, F2, F3, E1 pending — pursue only if the user asks).
- The auto-loaded memory files (`toolchain-vivado-only`,
  `comment-style-no-internal-ids`).

**HARD CONVENTIONS (also in memory — do not violate):**
- **Vivado only.** Do NOT run the locally-installed ModelSim/Intel tools (not even
  for a syntax check). Do NOT alter the canonical `tokenizer-csr/*.mem` files for
  any simulator's sake.
- **Comments in synthesizable RTL** must be plain and self-explanatory for the
  partner/professor — **no internal IDs** (no `H1`/`M1`/`FIX:`/`(M2)` etc.). The
  bug→fix mapping lives in `JOURNAL.md`. Testbenches may keep their `H1/M1/M2`
  labels (the user chose to leave those).
- **Output token IDs must always stay identical to HuggingFace bert-base-uncased.**
- Verify edits by re-reading; check `begin/end`, `task/endtask`, `module/endmodule`
  balance (e.g. `sed 's://.*::' f.v | grep -ow begin|wc -l`) since you can't run a
  compiler here.

**ARCHITECTURE (quick):** TCP → input FIFO (256×8) → `pre_tokenizer` (lowercase,
10-bit char map, boundary detect, **pure valid/ready flow control**) → `trie_engine`
(greedy longest-match WordPiece over two CSR tries — root 56,719 nodes/56,718 edges,
continuation 7,864/7,863; per trie 4 BRAM arrays: row_ptr 32b, edges 32b,
is_terminal 8b, token_ids 16b; 10-state FSM doing a binary search per node; 32×10
LUTRAM backtracking buffer) → output FIFO (256×16) → AXI-Lite → MicroBlaze.
**STATUS register bits:** 0 = input has space, 1 = token available, 2 = output
overflow (sticky; write to STATUS clears it), 3 = pipeline_busy.

**DONE & VERIFIED in Vivado (details in JOURNAL):**
- **H1** spurious `[UNK]`/dropped token at a word boundary during backtracking (trie FSM).
- **H2** binary-search index underflow at node 0 (trie).
- **M1** word longer than the 32-entry buffer → safe single `[UNK]` (trie).
- **M2** silent output-FIFO overflow → sticky detect flag on STATUS bit 2 (axi wrapper).

**DONE, AWAITING VERIFICATION:**
- **M3** (`echo.c`): forward raw bytes, no per-TCP-segment synthetic boundary →
  words split across segments tokenize correctly. Needs an on-board TCP check.
- **M4** (`echo.c` + RTL): replaced the ~500 µs blind drain delay with a real
  `pipeline_busy` (STATUS bit 3) + drain-while-sending; this also closes M2's
  *prevention* side. Needs Vivado + on-board check.
- **P1** (`pre_tokenizer` + `trie_engine`): removed the pre-tokenizer's two-phase
  word-boundary ack handshake (now pure valid/ready flow control); the trie lowers
  `ready` on `S_IDLE→S_EMIT`; the trie exposes a `busy` output.
- **CURRENT DEBUG STATE:** `tb_axi_pipeline`'s first run FAILED → diagnosed a
  1-cycle `pipeline_busy` *false-idle* at word boundaries (the `out_word_done`
  pulse ended at cycle T but the trie lowered `ready` only at T+2) → **fixed** by
  driving `pipeline_busy` from the trie's new
  `busy = (state!=S_IDLE) || !ready || replaying || word_done_pending`
  (`top_tokenizer`: `pipeline_busy = pt_busy || trie_busy`). TB hardened to print
  token IDs and isolate tests. **Re-run is pending — interpret it before anything else.**

**TESTBENCHES** (`uart.srcs/sim_1/new/`): `tb_fixes.v` (H1/H2/M1 — passed),
`tb_m2_overflow.v` (M2 — passed), `tb_axi_pipeline.v` (P1/M4 — re-run pending).
The original tbs (`tb_trie_engine`, `tb_top_tokenizer`, `tb_tokenizer_axi_lite`,
`tb_pre_tokenizer`, `tb_perf_measurement`) are unchanged; note `pre_tokenizer` and
`top_tokenizer` gained output ports, so those two original tbs now show a harmless
"unconnected output" warning.

**PENDING after `tb_axi_pipeline`:**
1. On-board (TCP) verification of M3 + M4 (latency drop vs old build; split-word
   correctness — e.g. send `embed`, pause, `ding\n` → expect `embedding`).
2. Remaining review items: **L1** (`.mem` hex widths don't match reg widths —
   cosmetic in Vivado, only via the Python generator), **L3** (AXI read re-triggers
   if a master holds `arvalid` — minor robustness).
3. Optional optimizations from `OPTIMIZATION_OPTIONS.md` — only if the user asks.

**Known-good token vectors** (for tests): `hello`→7592; `hardware`→8051;
`embedding`→7861 8270 4667; `unquestionably`→4895 15500 3258 8231;
`hello hardware`→7592 8051; `the quick brown fox jumps over the lazy dog`→
1996 4248 2829 4419 14523 2058 1996 13971 3899.
