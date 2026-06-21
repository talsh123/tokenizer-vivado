# FPGA WordPiece Tokenizer — Code Review

**Date:** 2026-06-18
**Scope:** Hand-written sources across the three projects (`tokenizer-csr`, `tokenizer-vivado`, `tokenizer-vitis`).
**Not reviewed:** Auto-generated Vivado IP, lwIP/BSP tree, `.xsa`/bitstream artifacts.

---

## 1. Overview — what the three projects are

Together they implement a **hardware WordPiece (BERT) tokenizer** on a MicroBlaze SoC (Nexys Video / Artix-7).

| Project | Role |
|---|---|
| **tokenizer-csr** | Offline Python toolchain. `vocab_parser.py` reads BERT's 30,522-entry `vocab.txt`, builds two tries (root + `##` continuation), CSR-compresses them, and emits the `.mem` files that initialize the FPGA BRAMs. |
| **tokenizer-vivado** | The RTL. Custom IP `tokenizer_axi_lite.v` wrapping `top_tokenizer.v` → `pre_tokenizer.v` + `trie_engine.v`, plus a MicroBlaze block design and 5 testbenches. |
| **tokenizer-vitis** | The embedded software. Modified lwIP echo server `echo.c`: receives TCP text on port 7, streams bytes to the IP over AXI-Lite, drains token IDs back. |

**Data path:**
`TCP → input FIFO → pre-tokenizer (lowercase / char-map / word-boundary) → trie engine (dual-trie greedy longest-match + backtracking) → output FIFO → TCP`

**Verified consistent:**
- `.mem` line counts match the RTL parameters exactly (root 56719 nodes / 56718 edges, cont 7864 / 7863, 30522 vocab lines).
- CSR bit-packing in Python matches the Verilog field slicing:
  - row_ptr: `offset<<16 | count` ↔ `[31:16]` / `[15:0]`
  - edges: `char<<17 | dest` ↔ `[31:17]` / `[16:0]`

---

## 2. Strengths

- Sound architecture: CSR compression to fit BRAM; dual root/continuation tries to model `##` pieces; binary search over sorted edges.
- Both tries are read every cycle so the `use_root` mux switches with **zero extra latency**.
- Exceptional inline commenting.
- Memory files and RTL parameters are in sync (the hardest thing to get right here).

---

## 3. Findings by severity

### HIGH — correctness bugs to verify in simulation

#### H1. `trie_engine.v` S_EMIT: missing `else` on the replay-completion path → spurious `[UNK]` / lost token
- **Where:** `trie_engine.v` lines ~264–273 and ~409–436.
- **What:** When a backtrack replay finishes *and* a word boundary is already pending, the code **clears `word_done_pending` to 0** and jumps to `S_EMIT`. But `S_EMIT`'s "match consumed all characters" branch (`best_end == buf_end`) only finalizes the word *inside* `if (word_done_pending)` — now false — and has **no `else`**. `state` is therefore never reassigned, so the FSM re-enters `S_EMIT`; `has_best_match` is now 0, so it emits a **spurious token 100 (`[UNK]`)**. The sibling branch (`best_end != buf_end`) starts another replay with `word_done_pending` already lost, so the final tail piece can get stuck/unflushed.
- **Reachability:** Only when a word boundary is latched *while a backtrack replay is in flight*. The provided vectors ("embedding", "unquestionably") flush their last piece via the *streaming* word-done path (line ~230, which deliberately does **not** clear `word_done_pending`), so they likely pass and hide this.
- **Action:** Add a directed self-checking sim that forces a backtrack to complete on the last character with the space already buffered (e.g. feed characters with no inter-char gaps, or a word like `"...ions "` whose final segment itself backtracks).
- **Fix options:**
  - Give the `best_end == buf_end` branch an `else` that finalizes the word (reset pointers, `use_root<=1`, handle `pending_char`, assign `state`) independent of `word_done_pending`; **or**
  - Do not pre-clear `word_done_pending` at line ~265 and let `S_EMIT` own it.

#### H2. Binary-search bound underflow at a trie's node 0
- **Where:** `trie_engine.v` `S_EVAL` line ~361 (`bs_hi <= edge_rd_addr - 16'd1`) and the guard at line ~336 (`if (bs_lo > bs_hi)`).
- **What:** `bs_hi`/`bs_lo` are unsigned. For any node with `offset > 0` the search terminates safely. But for **node 0** (`offset == 0`), if `target_char` is smaller than the node's first edge char, `bs_hi` underflows to `0xFFFF`, the `bs_lo > bs_hi` guard fails, and the search reads garbage edges (wrong token, or runaway).
- **Reachability:** Node 0 is hit on the first char of every word/segment. The **root** trie is safe in practice (its node 0 has a child at char index 0 = `'!'`, smaller than any letter/digit). The **continuation** trie is the risk: feeding a digit/letter whose index is below every continuation piece's first char triggers it.
- **Fix:** Guard with `if (edge_rd_addr == 0) state <= S_EMIT; else bs_hi <= edge_rd_addr - 1;` or use a signed/extra guard bit.

---

### MEDIUM — robustness / silent data loss

#### M1. No long-word protection
- `char_buf` is `BUF_DEPTH=32` and `buf_end` is 5-bit (`trie_engine.v` ~line 164). A word > 32 characters wraps `buf_end` and corrupts the buffer with no guard. Real BERT applies `max_input_chars_per_word` (→ `[UNK]`). Add a guard that forces `[UNK]` past the buffer limit.

#### M2. Output FIFO overflow is silent
- `tokenizer_axi_lite.v` ~line 139: if `out_fifo_full`, the emitted token is dropped — the trie engine has no backpressure from the output FIFO. A 256-byte input can produce ~256 tokens (worst case all `[UNK]`), filling the 256-deep FIFO before `echo.c` drains it. Stall the engine on full, or document the input-size limit.

#### M3. `echo.c` treats every TCP segment as word-final
- `echo.c` ~lines 144–150 append a space after *each* `pbuf`. A word split across two TCP segments is tokenized as two words → wrong IDs. Fine for short telnet lines; worth a comment or reassembly for larger inputs.

#### M4. Blind 50,000-iteration drain delay
- `echo.c` ~line 161 (already flagged in its comment). A "pipeline idle" status bit (or using `word_boundary_busy`/FIFO-empty) would make draining deterministic and faster.

---

### LOW / cosmetic

#### L1. token_ids `.mem` are 32-bit, the reg is 16-bit
- `vocab_parser.py` ~line 195 writes `{tid:08X}` (8 hex digits) into `reg [TOKEN_W-1:0]` (`trie_engine.v` ~line 56). Functionally fine (values < 65536, upper bits zero) but `$readmemh` will emit width-mismatch warnings. Use `{tid:04X}` to match.

#### L2. `[UNK]`/100 path is untested
- None of the 5 testbenches assert a `16'd100` result, and none feed a word that misses the vocab, exceeds 32 chars, has digits, or overflows the output FIFO. These are exactly the paths most likely to harbor the bugs above. Tests are also fixed-wait + count/value checks, which won't catch the timing-dependent issue H1.

#### L3. AXI read re-trigger if `arvalid` held
- `tokenizer_axi_lite.v` ~line 236: `if (s_axi_arvalid && !s_axi_rvalid)` will start a second read (and pop the FIFO again) if a master keeps `arvalid` high across the `rready` handshake. MicroBlaze/`Xil_In32` deasserts properly so it's safe today, but it is not strictly AXI-robust.

---

## 4. Suggested priority order

1. **H1** — write a directed self-checking sim that forces a backtrack to land exactly on the word boundary (most likely to bite on real text), then fix.
2. **H2** — cheap underflow guard.
3. **M1 / M2** — cheap hardening against long words and output overflow.
4. Remaining medium/low items as time allows.

---

## 5. Quick-reference table

| ID | Severity | File | Issue |
|----|----------|------|-------|
| H1 | High | `trie_engine.v` (~264–273, ~409–436) | Missing `else` in S_EMIT → spurious `[UNK]` / lost token on replay+word_done |
| H2 | High | `trie_engine.v` (~336, ~361) | Binary-search `bs_hi` underflow at node 0 |
| M1 | Medium | `trie_engine.v` (~164) | No guard for words > 32 chars (buffer corruption) |
| M2 | Medium | `tokenizer_axi_lite.v` (~139) | Silent output-FIFO overflow (no backpressure) |
| M3 | Medium | `echo.c` (~144–150) | Each TCP segment treated as word-final |
| M4 | Medium | `echo.c` (~161) | Blind 50k-iteration drain delay |
| L1 | Low | `vocab_parser.py` (~195) | 32-bit token_ids `.mem` into 16-bit reg (warnings) |
| L2 | Low | `tb_*.v` | No `[UNK]` / long-word / digit / overflow coverage |
| L3 | Low | `tokenizer_axi_lite.v` (~236) | AXI read re-trigger if `arvalid` held high |

---

## 6. Resolution status (updated 2026-06-21)

**All review findings H1–L3 are FIXED and verified.** Per-problem detail (engineering field,
defect, surgical fix, verification evidence, status) is in `JOURNAL.md`; one-line summary here:

| ID | Status | Fix (summary) | Verified |
|----|--------|---------------|----------|
| H1 | ✅ Fixed | `S_EMIT` replay-completion path finalizes the word independent of `word_done_pending` (no spurious `[UNK]`/lost tail) | xsim + on-board |
| H2 | ✅ Fixed | node-0 binary-search underflow guarded (`edge_rd_addr==0 → S_EMIT`) | xsim + on-board |
| M1 | ✅ Fixed | words > 32 chars forced to a single `[UNK]` instead of buffer corruption | xsim + on-board |
| M2 | ✅ Fixed | output-FIFO overflow → sticky STATUS bit 2; M4 drain-while-sending also prevents the drop | xsim |
| M3 | ✅ Fixed | `echo.c` forwards raw bytes (no per-segment synthetic boundary) | on-board TCP |
| M4 | ✅ Fixed | real `pipeline_busy` STATUS bit 3 + deterministic drain replaces the blind ~500 µs delay | `tb_axi_pipeline` + on-board |
| P1 | ✅ Fixed | pre-tokenizer pure valid/ready flow control + trie input skid + boundary-char capture | `tb_axi_pipeline` + on-board |
| L1 | ✅ Fixed | `vocab_parser.py` writes token-id `.mem` as 4-hex to match the 16-bit reg | regen + xsim (no warnings) |
| L2 | ✅ Fixed | added `[UNK]`/digit/long-word/overflow coverage across the testbenches | xsim |
| L3 | ✅ Fixed | AXI read gated with `read_addr_serviced` (no re-trigger / double-pop if `arvalid` held) | xsim |

(Plus two synthesis-warning cleanups: `char_buf` `ram_style` attribute removed, and `tok_word_busy`
declaration moved ahead of first use.)

---

## 7. New architecture — R2: AXI-Stream + AXI DMA datapath (2026-06-21)

After the review fixes, the dominant on-board cost was the **byte-by-byte AXI-Lite MMIO loop** in
`echo.c` (poll STATUS + write `TX_DATA` per byte, poll + read per token) — ~1 ms for a 43-char line
against ~10 µs of actual fabric work. **R2 replaces the transport** (the tokenizer core is untouched,
so token IDs are bit-identical):

**RTL (`tokenizer_axi_lite.v`, additive — AXI-Lite path unchanged):**
- 8-bit AXI4-Stream **slave `s_axis`** feeds the existing input FIFO (`s_axis_tready = !in_fifo_full
  && !in_fifo_wr_en`; FIFO write gained an `else if (s_axis_fire)` branch).
- 16-bit AXI4-Stream **master `m_axis`** (one token per beat) drains the output FIFO (pop on
  `out_fifo_rd_en || m_axis_fire`).
- **TLAST framing:** `input_done` latches on the accepted `s_axis_tlast` byte; `m_axis_tlast =
  m_axis_tvalid && out_fifo_one_left && input_done && !producing` — asserted on the token that empties
  the FIFO once nothing more can be produced.
- New **`TOKEN_COUNT (0x0C)`** register (write-to-clear, increments per enqueued token): simple-mode
  S2MM doesn't report received length, so firmware reads the count here.
- Clock association via `(* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis:m_axis ..." *)` on
  `s_axi_aclk` (clears `BD 41-967`).

**Block design:** AXI DMA (Simple mode, MM2S 8-bit / S2MM 16-bit), MM2S → `s_axis`, `m_axis` → S2MM,
direct (no width converters), all on the 100 MHz clock; DMA buffers live in DDR (`0x8xxx_xxxx`).

**Firmware (`echo.c`):** `tokenizer_dma_init()` (SDT/base-address `XAxiDma` lookup — ours is
`0x41E10000`, *not* the ethernet DMA at `0x41E00000`) + `tokenizer_dma_run()` (clear count → flush
input → arm S2MM → kick MM2S → poll both → invalidate → read count). `recv_callback` does one DMA
round-trip per segment.

**Two bring-up defects found & fixed (full detail in `JOURNAL.md`):**
- **Stale bitstream masquerading as a hardware fault** — `TOK_COUNT=0` despite correctly-wired
  `s_axis`/`m_axis` (proven via firmware self-tests + `design_1.hwh` connectivity check); the
  programmed bitstream wasn't the final build. Lesson: suspect the bitstream first.
- **Zero-token TLAST hang** — boundary-only segments (telnet's `\r\n`) produce no token, so TLAST
  never asserts and the simple-mode S2MM transfer hangs the lwIP callback → connection abort. Fixed
  in `recv_callback` by never launching a DMA that can't produce ≥1 token (+ a bounded poll timeout).

**Verified on-board:** all golden vectors correct; **~14× faster than MMIO** on the pangram
(~1000 µs → 70 µs), advantage widening with input length (DMA latency flat ~54–72 µs vs MMIO linear).

---

## 8. Known limitations (from the 66-line corpus evaluation, 2026-06-21)

Measured against HuggingFace `bert-base-uncased` over a realistic 66-line corpus (`analysis/`):
originally **97% (64/66)**; now **100% (66/66)** after the one-character-word fix below (sim-verified;
on-silicon once the fixed bitstream is flashed). The remaining differences are by-design, not silent:

- **Punctuation is dropped by design.** `pre_tokenizer.v` treats every non-`[a-z0-9]` byte as a word
  boundary and emits no standalone-punctuation token, whereas BERT emits one per punctuation mark.
  This accounts for **13.6%** of BERT's tokens across the corpus. Expected and documented, not a bug.
- **One-character-word merge bug — ✅ FIXED (was 2/66 lines).** A one-character word that *immediately
  follows a multi-subword word* failed to flush at its trailing boundary and was concatenated with the
  next word: `...summarize a long pdf...` → `along` (idx 27); `...vocab[t] ?? vocab...` → `tvocab`
  (idx 62). **Root cause:** `trie_engine.v`'s `word_done_pending` was a *single bit*; when a 1-char
  word's boundary arrived while the previous multi-piece word was still replaying (the racing-char
  skid having pulled the 1-char word in early), the second boundary collided with the first
  (`1|1 = 1`) and was lost. **Fix:** `word_done_pending` → `word_done_count`, a 2-bit saturating
  counter (+1 per boundary, −1 per finalize), so colliding boundaries are preserved. **Verified:**
  new `tb_word_boundary.v` (8/8, incl. `summarize a long`, `vocab t vocab`, `embed embedding a hi`)
  and the full corpus 64/66 → **66/66**, `inspect_mismatch.py` 0 mismatches. Sim-only fix (no vocab
  change); detail in `JOURNAL.md` "Bug #2 fixed" and `analysis/evidence/MISMATCH_REPORT.md`.
- **ASCII only.** Non-Latin / accented / emoji input is unsupported (the `analysis/divergence.txt`
  set); BERT normalizes Unicode. Out of scope for the hardware char map.
- **Fixed vocabulary in BRAM.** Changing the vocabulary requires re-running `vocab_parser.py` and
  re-synthesizing; the CPU just loads a different file.

---

## 9. Hardening pass (2026-06-21)

A final six-item triage after the evaluation. Workflow rule: verify every RTL/BD change in
simulation, then a **single** synthesis/implementation run, then the firmware (Vitis) items — to
avoid repeated long implementation runs.

| # | Item | Resolution | Where |
|---|------|------------|-------|
| #2 | 1-char-word-after-multipiece merge | ✅ **Fixed in RTL, sim-verified 66/66** (`word_done_count` counter) — see §8. **NOT yet on silicon** (2026-06-22): blocked first by auto-incremental synthesis reusing the pre-fix partition (fixed by disabling incremental), now by the Tri-Mode Ethernet MAC bitstream license. Board still runs the pre-fix bitstream. | `trie_engine.v` |
| #1 | Post-route timing **WNS −0.374 ns** (2/87,343 endpoints) | ✅ **Documented benign**: both failing paths are `ASYNC_REG=1` CDC reset synchronizers **inside the AMD Tri-Mode Ethernet MAC** (`clkout0 → clkout1`, a clock and its phase-shifted sibling); all user logic meets timing with **+0.6 ns**. Evidence: `analysis/results/timing_failing.rpt`. | (vendor IP) |
| #7 | Zero-token DMA can't signal TLAST | ✅ **Firmware**: AXI-Stream TLAST must ride a data beat, so the `has_word` guard (never arm a 0-token DMA) is the correct fix; added `tokenizer_dma_recover()` to reset the DMA on any MM2S/S2MM timeout so a stall can't wedge the server. | `echo.c` |
| #8 | Cache invalidate over-broad | ✅ **Firmware**: post-transfer D-cache invalidate sized to `ntok×2` B (read `TOKEN_COUNT` first) instead of the full 2 KB buffer. | `echo.c` |
| #9 | `init_calib_complete` not in reset path | ⏸️ **Deferred** (documented): correct fix is `AND(clk_wiz_1/locked, init_calib_complete) → rst_clk_wiz_1_100M/dcm_locked` (the block that resets MicroBlaze + peripherals — **not** the MIG reset block). Theoretical race only (ms of BRAM boot vs µs of calibration); deferred to protect the single implementation run. | block design |
| #10 | PHY patch wiped on every BSP regen | ✅ **Durable mechanism**: canonical patched copies kept as `lwip_echo_server/src/phy_patch/*.c.golden` (`.golden` so the IDE can't auto-compile them → would dup-link) + `apply_phy_patch.ps1` for one-command re-apply after any `.xsa` re-read. | Vitis app |

**Regression safety:** the #2 rename (`word_done_pending → word_done_count`) broke one internal-signal
probe in `tb_axi_pipeline.v` (now updated). `analysis/run_all_tbs.tcl` runs all 12 testbenches in one
action with a PASS/FAIL summary. Post-impl reports are regenerated by `analysis/gen_reports.tcl`.

**Build gotcha (the real cause was AUTO-INCREMENTAL SYNTHESIS):** after editing tokenizer RTL, a
rebuild can keep old logic in the bitstream even though source + simulation are fixed. Caught on-board
2026-06-21/22: the #2 fix was sim-verified 66/66 but the re-flashed board still showed the old merge.
Root cause = **auto-incremental synthesis** (`AutoIncrementalCheckpoint="true"` in the `.xpr`) reusing
a pre-fix tokenizer partition from a stale reference checkpoint; Reset Output Products did NOT fix it.
Fix: delete `uart.srcs/utils_1/imports/synth_1/design_1_wrapper.dcp` and disable incremental
(`set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]`), then `reset_run synth_1` + full
rebuild. **Verify reliably** with `open_run impl_1; get_cells -hierarchical -filter {NAME =~
*word_done_count*}` (must be > 0) — do NOT grep `uart.runs` (the `.rpx` reports are binary → false
matches). Note: the full (non-incremental) build re-synthesizes the Tri-Mode Ethernet MAC, which needs
a bitstream license (hardware-evaluation is free, time-limited) — see `CONTINUATION_PROMPT.md`.
