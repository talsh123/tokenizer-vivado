# Continuation prompt (RTFC) — FPGA WordPiece Tokenizer

Paste this into the new chat, or just tell the new chat: "read HANDOFF.md and continue."
(RTFC = Role · Task · Format · Context.)

---

## ⭐ CURRENT STATUS (latest — read this first; the RTFC below is the original, now stale)

**Project moved** to `C:\Users\talsh\.Xilinx\projects\uart` (was under a non-synced
`...\OneDrive\...` folder; no actual OneDrive). All edits go here now.

**DONE & verified in Vivado behavioral sim (xsim):** H1, H2, M1, M2, **P1** (pre-tok pure
valid/ready + trie input skid), **M4** (`pipeline_busy` STATUS bit 3 incl. `tok_out_valid`
emit-cycle term), and the **embed boundary char-drop fix** (S_EMIT replay-launch capture).
Full `tb_axi_pipeline` is green incl. slow-cadence tests (`embed (slow)`, `embed hardware
(slow)`). Timing closes clean.

**Firmware `echo.c` (Vitis project `C:\Users\talsh\Vitis\final_project_eth_nexys_video`):**
M3 (raw-byte forwarding, no synthetic boundary) + M4 (`tok_pipeline_busy()`, drain-while-
sending, boundary-aware final drain) + multi-line-output fix (append `\r\n` only when the
segment ended on a boundary). On-board: ethernet up, normal words correct, M4 latency floor gone.

**BSP PHY patches — RE-APPLY AFTER EVERY BSP REGEN (they get wiped):** `xadapter.c`
(`axieth_link_status` first_link/hardcode-100) and `xaxiemacif_physpeed.c` (`get_IEEE_phy_speed`
Realtek `0x001c` branch). Full verbatim code is in `.claude-memory/vitis-bsp-phy-patches.md`
(and Claude memory). A BSP regen on 2026-06-20 wiped them again — confirm before each board build.

**OPEN ISSUE — board-only spurious `[UNK]` (token 100) on "embed"-class words:** the board
returns `embed ` → `7861 8270 100` (and `embed hardware` → `7861 8270 100 8051`), but
**behavioral sim is clean at every byte cadence** (no `has_best=0` cycle). Synthesis log confirms
all 9 `.mem` BRAM inits loaded OK, bitstream timestamps are post-fix, and `.mem` copies match —
so it's NOT data loss/stale-source by those checks. Working theory: stale synthesized RTL from
Vivado caching, OR a synthesis/hardware behavioral difference. **NEXT STEP:** clean rebuild at the
new path (Reset Synthesis+Implementation to force full re-read → re-synth → re-impl → bitstream),
re-apply BSP patches, reprogram, re-test `embed`. If it persists: post-implementation timing sim
(the tokenizer is the OOC IP `design_1_tokenizer_axi_lite_0_0`, so it has a netlist) or an ILA on
`out_token_valid`/`out_token_id` triggered on token==100.

**Vivado gotchas hit this session (not a sync issue — no OneDrive):** the editor buffer can
overwrite disk on sim launch; xsim reuses stale compiled snapshots. Always **Reset** the sim/run
to force a real recompile; close a file in the editor before editing it externally.

**`tb_axi_pipeline.v` has a temp debug probe + slow tests (Test 7/8)** — fine to keep for now;
remove the `===== TEMP DEBUG PROBE =====` block for the final clean version.

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
