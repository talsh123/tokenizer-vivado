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
