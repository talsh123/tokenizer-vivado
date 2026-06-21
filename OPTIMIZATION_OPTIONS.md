# FPGA WordPiece Tokenizer — Speed & Efficiency Options

Prioritized optimizations to make the design **faster** (higher throughput, lower
latency per character/word) and **more efficient** (higher fmax, lower BRAM/LUT/FF)
**without changing the token IDs** (must stay identical to HuggingFace
`bert-base-uncased`).

Grounded in the actual RTL:
[trie_engine.v](tokenizer-vivado/uart.srcs/sources_1/new/trie_engine.v),
[pre_tokenizer.v](tokenizer-vivado/uart.srcs/sources_1/new/pre_tokenizer.v),
[tokenizer_axi_lite.v](tokenizer-vivado/uart.srcs/sources_1/new/tokenizer_axi_lite.v),
the CSR generator [vocab_parser.py](tokenizer-csr/vocab_parser.py),
and the MicroBlaze driver [echo.c](tokenizer-vitis/lwip_echo_server/src/echo.c).

> **Headline finding (original):** the biggest wall-clock cost was the
> `for (volatile int d = 0; d < 50000; d++);` blind delay at
> [echo.c:161](tokenizer-vitis/lwip_echo_server/src/echo.c#L161): ~500 µs per packet against
> a ~10 µs tokenization.
>
> **✅ UPDATE (2026-06-20): F1 is DONE** — shipped as review item **M4**. The blind delay is
> replaced by a `pipeline_busy` STATUS bit (bit 3) plus drain-while-sending; the per-packet floor is
> gone and latency now scales with token count (a 0-token segment is ~25 µs, ~140 µs/token after).
> **The new dominant on-board cost is the per-byte MMIO loop** — see **R2 (DMA)**, which is now the
> next priority and the handoff item for the next engineer (Rafi).

---

## 1. Summary table

| #  | Option | Dimension | Est. benefit | Effort | Risk |
|----|--------|-----------|--------------|--------|------|
| F1 ✅**DONE** (=M4) | Replace the 500 µs SW busy-wait with a "pipeline-busy" STATUS bit + drain loop | (f) system | **delivered: ~25–50× end-to-end** (blind floor removed) | XS (1 RTL bit + C) | Low |
| C1 | Direct-indexed first-character table for each trie root node | (a)(c) trie | First char/word ~35→~4 cyc; ~20–25% off total trie cycles | S–M | Low* |
| A1 | Fold `is_terminal`+`token_id` into the edge record (kill the terminal read) | (a)(b)(d) | −2 cyc/char; frees the whole `is_terminal` BRAM | M | Low* |
| A2 | Merge S_EVAL with next-midpoint issue (3→2 cyc per probe) | (a)(b) | −1 cyc per binary-search probe (~−⅓ of search) | S | Low |
| A3 | Merge S_ROW_READ with first-midpoint issue (drop S_CALC_MID) | (a)(b) | −1 cyc/char | S | Low |
| D1 | Drop standalone 8-bit `is_terminal` array (subsumed by A1) | (d) area | ~14–16 RAMB36 freed (root+cont) | S (with A1) | Low* |
| F2 | Skip per-byte STATUS poll for inputs ≤ FIFO depth (write-only fast path) | (f) system | ~½ the send-phase AXI reads | S | Low |
| E1 | BRAM output-register / pipeline FSM arithmetic for higher fmax | (e) fmax | Headroom toward 150–200 MHz | M | Med |
| R1 | Hybrid "fat node" format: inline edges + parallel compare for small nodes | (a)(c) | Most chars → ~3–4 cyc, no search loop | M–L | Med* |
| R2 ⭐**NEXT / handoff** | AXI-Stream + DMA instead of MMIO byte-banging | (f) system | **now the dominant on-board cost** (~50–100 cyc/byte MMIO); high | L | Med |
| F3 | Interrupt-driven output drain instead of polling | (f) system | CPU offload, multi-conn scaling | M | Low |

\* = output-preserving *by construction* but touches table format or search logic, so
it must be re-verified against the HuggingFace golden vectors. See [§4](#4-output-regression-risk--verify-carefully).

---

## 2. Detailed options, by dimension (highest ROI first)

### (f) System-level throughput — *this is where the wall-clock time actually is*

**F1 — Kill the 500 µs busy-wait. ✅ DONE — shipped as review item M4.** Implemented exactly as
described below: a `pipeline_busy` STATUS bit (bit 3) in `tokenizer_axi_lite.v` plus a
`while (tok_pipeline_busy() || tok_has_token()) drain;` loop and drain-while-sending in `echo.c`.
The blind delay is removed; per-packet latency now scales with the work. The original write-up is
kept below for the report record.
[echo.c:161](tokenizer-vitis/lwip_echo_server/src/echo.c#L161) spins ~50,000
iterations (~500 µs) after sending bytes, "to give the hardware time," then drains
with `while(tok_has_token())`. The blind delay exists only because there's no way to
ask "is the pipeline still working?" — and without it the drain loop can race ahead of
the first token and exit early. **Mechanism:** add one STATUS bit
`pipeline_busy = !(in_fifo_empty && out_fifo_empty && trie_ready && !word_boundary_busy)`
in [tokenizer_axi_lite.v](tokenizer-vivado/uart.srcs/sources_1/new/tokenizer_axi_lite.v)
(the STATUS read at
[line 279](tokenizer-vivado/uart.srcs/sources_1/new/tokenizer_axi_lite.v#L279) already
packs spare bits), then in C:
`while (pipeline_busy() || tok_has_token()) { if (tok_has_token()) drain(); }`.
**Benefit:** the per-packet floor drops from ~510 µs to the actual ~10–20 µs of compute
— **25–50× end-to-end**, and it scales with input instead of being a fixed tax.
**Effort:** ~1 RTL bit + ~3 C lines. **Risk:** low (pure status signal). This single
change makes the fabric micro-optimizations below actually visible to the user.

**F2 — Write-only fast path for short inputs.** `tok_send_byte()` polls STATUS before
*every* byte ([echo.c:77](tokenizer-vitis/lwip_echo_server/src/echo.c#L77)). The input
FIFO is 256 deep; for the typical sub-256-char packet it can never fill during a tight
send loop, so the read-poll-per-byte is pure overhead (each AXI-Lite read is several
MicroBlaze bus cycles). **Mechanism:** if `p->len ≤ 256`, write all bytes without
polling; otherwise chunk in ≤256 blocks with one space-check per block. **Benefit:**
~halves send-phase AXI transactions. **Effort:** small. **Risk:** low (must keep the
chunking guard for >256).

**R2 — AXI-Stream + DMA instead of MMIO. ⭐ NEXT PRIORITY — handoff item for Rafi.** With F1/M4
done, this is now the dominant on-board cost and the single "must-do" remaining. Today the CPU moves
one byte / one token per AXI-Lite beat, spending ~50–100 MicroBlaze cycles of software overhead per
byte (poll STATUS, write `TX_DATA`); a 43-char line measured ~1.1 ms end-to-end against ~10 µs of
actual fabric tokenization — i.e. the system is **MMIO-bound, not fabric-bound**. **Mechanism:** add
an AXI-Stream slave (input) and master (output) on the tokenizer IP, drop an AXI DMA (or AXI4 burst
master) into the block design, and rewrite `echo.c` to hand the RX buffer to a DMA descriptor
instead of the `tok_send_byte()` loop and to drain tokens via a DMA S2MM transfer instead of the
per-token `RX_DATA` reads. Bytes then stream in / tokens stream out at ~1 per clock with no
per-element CPU involvement. **Benefit:** removes the per-byte software tax — the win grows with
input length and frees the CPU for TCP. **Effort:** large (block-design + IP port changes + driver
rewrite + re-verify). **Risk:** medium. **Handoff notes for whoever picks this up:**
- The tokenizer IP today exposes only AXI-Lite (`tokenizer_axi_lite.v`); the FIFOs inside it
  (`in_fifo`/`out_fifo`) are the natural attach points for AXI-Stream — feed the input FIFO from an
  S2MM-style stream and source the output FIFO to an MM2S-style stream, keeping the existing
  pre-tokenizer/trie pipeline untouched so **token IDs stay identical**.
- Keep `pipeline_busy` (M4) — DMA still needs a "tokenization complete" signal to know when the last
  token has been produced before the S2MM drain.
- **Re-verify against the full HuggingFace golden vectors** after the rewrite (see [§4](#4-output-regression-risk--verify-carefully)); the datapath that produces IDs does not change, but the
  framing/length handling in firmware does, so confirm multi-word, `[UNK]`, and >256-char cases.
- **F2** (write-only fast path) and **F3** (interrupt-driven drain) below are smaller, lower-risk
  stepping stones if a full DMA integration is too big for the timeline.

**F3 — Interrupt-driven drain.** Route output-FIFO-non-empty (or F1's pipeline-done) to
a MicroBlaze interrupt so the CPU isn't spinning. Mostly helps multi-connection scaling
and power, not single-stream latency. Medium effort, low risk.

### (a)(b) Cycles-per-character & BRAM-latency hiding

**C1 — Direct-indexed first-character jump table (best fabric ROI).** The root node has
~997 children, so the first char of every word costs ~10 binary-search probes
(~35–40 cyc) — and a 9-word sentence pays that ~9 times. But the root's children are
indexed directly by the 10-bit alphabet code. Precompute offline a 1024-entry table
`root_first[char] = {valid, dest_node}` (and the same for the continuation root). In
RTL, the first character of a word becomes a single BRAM read (≈2–4 cyc) instead of a
full search. **Mechanism:** new `.mem` from
[vocab_parser.py](tokenizer-csr/vocab_parser.py), one extra small BRAM, and an FSM
branch that uses it when `current_node==0`. **Benefit:** first-char ~35→~4 cyc; on the
pangram that's ~9×30 ≈ 270 cyc off ~1004 (~**20–25%**). **Effort:** small–medium.
**Risk:** low, but it's a table/search change → re-verify ([§4](#4-output-regression-risk--verify-carefully)).

**A1 — Fold terminal flag + token ID into the edge record (removes the terminal read
entirely).** Every matched edge currently lands on a node, then the FSM spends
`S_TERMINAL_WAIT`→`S_TERM_READ`
([lines 427–448](tokenizer-vivado/uart.srcs/sources_1/new/trie_engine.v#L427-L448)) to
look up `is_terminal`/`token_id` at the destination — 2 cyc every character. Since the
edge already carries the destination node id
([line 400](tokenizer-vivado/uart.srcs/sources_1/new/trie_engine.v#L400)), store the
destination's `terminal` bit and `token_id` *in the edge word*. Then `S_EVAL` has
everything the moment it finds the match — delete both terminal states. Edge grows from
32b → ~33b+16b; pack as `{char[15], term[1], dest[17], token[16]}` (≈49b, round to 64b).
**Benefit:** −2 cyc/char *and* it makes D1 free. **Effort:** medium (Python layout +
RTL). **Risk:** low, re-verify ([§4](#4-output-regression-risk--verify-carefully)).
**Caveat:** edges array widens (offset by D1's savings).

**A2 — Collapse each binary-search probe from 3 cycles to 2.** The loop today is
`S_CALC_MID`/`S_SEARCH` (issue addr) → `S_SEARCH_WAIT` (mandatory 1-cyc BRAM latency) →
`S_EVAL` (compare) — 3 cyc/probe
([lines 375–424](tokenizer-vivado/uart.srcs/sources_1/new/trie_engine.v#L375-L424)). The
BRAM latency forces one wait cycle, but the "narrow bounds + compute next midpoint +
issue next address" work can be done combinationally inside `S_EVAL` itself, going
straight back to `S_SEARCH_WAIT`. That removes the separate `S_SEARCH` cycle → 2
cyc/probe. **Benefit:** −⅓ of all search cycles (e.g. a 4-probe node: 12→8 cyc).
**Effort:** small. **Risk:** low; the only cost is a slightly longer combinational path
in `S_EVAL` (compare → subtract → shift → add → address), comfortably inside 10 ns at
100 MHz — watch it only if pushing fmax (see E1).

**A3 — Fold the first-midpoint computation into S_ROW_READ.** `S_ROW_READ` sets
`bs_lo/bs_hi` then hands off to `S_CALC_MID` just to compute the first midpoint
([lines 364–380](tokenizer-vivado/uart.srcs/sources_1/new/trie_engine.v#L364-L380)).
Compute that midpoint and issue the edge read in the same cycle the bounds are known,
deleting `S_CALC_MID`. **Benefit:** −1 cyc/char. **Effort:** small. **Risk:** low.
(A2+A3 together restructure the FSM to:
`S_IDLE → S_ROW_WAIT → S_ROW_READ(bounds+mid+issue) → [S_SEARCH_WAIT → S_EVAL]* → done`.)

> Net of A1+A2+A3+C1, a mid-word char with fan-out *F* goes from ≈ `5+3·⌈log₂F⌉` to
> ≈ `3+2·⌈log₂F⌉` cyc, and word-initial chars from ~35 to ~4.

### (c) Node/edge structure & per-node search

**R1 — Hybrid "fat node" format (larger redesign, big payoff).** The fan-out
distribution (`print_edge_stats` in
[vocab_parser.py:228](tokenizer-csr/vocab_parser.py#L228)) is extremely skewed: average
~1 edge, a handful of huge nodes. Binary search is overkill for the ~1–2-edge common
case (you still pay row-read + a probe). Define two node classes offline: **small** nodes
(fan-out ≤ K, e.g. 4) inline all their edges in the row record so one wide BRAM read
returns them and a parallel comparator picks the match in the same cycle — no search
loop; **large** nodes (the few high-fan-out, incl. roots) keep CSR + binary search, or
use C1's direct table. **Benefit:** the vast majority of characters drop to ~3–4 cyc
regardless of search, and the binary-search loop becomes rare. **Effort:** medium–large
(variable node format + Python + RTL). **Risk:** medium; re-verify
([§4](#4-output-regression-risk--verify-carefully)).

### (d) Memory layout & resource sharing

**D1 — Eliminate the standalone `is_terminal` BRAM.** It's an 8-bit array holding one
real bit per node
([lines 55,72](tokenizer-vivado/uart.srcs/sources_1/new/trie_engine.v#L55)). For 56,719
root nodes that's ~0.45 Mbit — Vivado will pack it into roughly a dozen-plus RAMB36s for
1 bit of information. Two ways to reclaim it: (a) via A1, the terminal bit moves into the
edge and the array vanishes; or (b) cheaper standalone, store terminal as the top bit of
`token_id` (token IDs max 30521 < 2¹⁵, so bit 15 is free) and drop the array.
**Benefit:** ~14–16 RAMB36 freed (root+cont), exact count depends on Vivado packing.
**Effort:** small (with A1, ~free). **Risk:** low, re-verify
([§4](#4-output-regression-risk--verify-carefully)). **Note:** `row_ptr`'s `count` field
only needs 10 bits (max fan-out ~997) vs the 16 allocated, but narrowing it doesn't cross
a RAMB width boundary, so it's not worth the churn.

> **Resource-sharing note:** the two tries are already read in parallel at *shared*
> address registers
> ([lines 116–128](tokenizer-vivado/uart.srcs/sources_1/new/trie_engine.v#L116-L128)) —
> merging them into one physical array would still need two read ports, so there's
> nothing to gain there; leave it.

### (e) Clock frequency / timing closure

**E1 — Get a real timing report, then trade latency for fmax where it's free.** 7-series
BRAM closes 100 MHz easily with 1-cycle latency, so today's fmax limiter is almost
certainly the FSM combinational logic or the wide distributed-RAM (`char_buf`,
`char_map`), not the memories — but without a post-route report this is a guess.
Concrete levers once you have it: enable the BRAM **output register** (2-cycle read) on
the *root* arrays for fmax headroom (costs +1 cyc/access — only worth it if you're
chasing >150 MHz and have absorbed the cycle wins above), and register the `S_EVAL`
midpoint arithmetic if A2 makes it the critical path. **Effort:** medium. **Risk:**
medium (latency/fmax trade). **Open question:** what does the current Vivado timing
report show as the failing/near-critical path? That determines whether fmax work is even
worth it.

---

## 3. Closing split

### Done
- **F1** ✅ — pipeline-busy STATUS bit + drained wait loop, shipped as review item **M4**. The blind
  ~500 µs per-packet floor is gone; latency now scales with token count.
- **R2** ✅ — AXI-Stream + AXI DMA datapath, shipped and verified on-board (**~14× vs MMIO**; DMA
  latency flat ~54–72 µs). See §(f) R2 above and `CODE_REVIEW.md` §7.
- **Correctness #2** ✅ (sim) — the 1-char-word-after-multipiece merge bug fixed (`word_done_pending`
  single bit → `word_done_count` saturating counter); corpus **64/66 → 66/66** (sim). **NOT yet on
  silicon (2026-06-22)** — blocked by a Vivado build issue (auto-incremental synthesis, then the TEMAC
  bitstream license); see `CONTINUATION_PROMPT.md`. Detail: `CODE_REVIEW.md` §8/§9.
- **Firmware hardening** ✅ — #7 DMA reset-on-timeout recovery, #8 `ntok×2`-sized cache invalidate, and
  #10 durable RTL8211E PHY patch (`lwip_echo_server/src/phy_patch/*.golden` + `apply_phy_patch.ps1`).

### Optimization options remaining (optional future work)
- R2 (the previous "must-do") is **done**. Everything below is optional; verify outputs carefully
  (see §4) before shipping any of it.

### Quick wins (small, low-risk, high return)
- **A2 + A3** — restructure the search FSM to 2 cyc/probe and drop `S_CALC_MID`. Pure
  RTL, output-identical, no table change.
- **F2** — write-only fast path for ≤256-char inputs (a smaller stepping-stone toward R2).
- **D1** (standalone variant) — terminal bit into `token_id`'s spare top bit; frees ~a
  dozen+ RAMB36.

### Larger redesigns (plan, schedule a verification pass)
- **C1** — direct first-character table per trie root (best fabric-cycle ROI; needs
  Python + golden re-verify).
- **A1** — fold terminal/token into the edge (kills the terminal read, makes D1 free;
  layout change).
- **R1** — hybrid fat-node format with parallel compare (removes the search loop for
  most chars).

### Open questions to sharpen the estimates
1. **Post-route Vivado timing report** — what's the current critical path and slack at
   100 MHz? Decides whether E1/fmax work is worthwhile and how aggressive A2 can be.
2. **Current BRAM utilization** (RAMB36/RAMB18 used vs the part's total) — sets how much
   headroom A1/D1 buy you and whether R1's wider records fit.
3. **Fan-out histogram** from `print_edge_stats` (max/avg, count >10, >50) — picks the K
   threshold for R1 and confirms how concentrated the binary-search cost is in the few
   big nodes.
4. **Real input mix** (typical packet length, words/packet) — F1+C1 dominate for short
   interactive text; R2 only pays off if large documents are common.
5. **Latency vs throughput priority** — is the goal lower per-request latency (favor F1,
   C1, A-series) or sustained streaming throughput (favor R2/DMA)?

---

## 4. Output-regression risk — verify carefully

None of the above is *designed* to change token IDs; every table/search change
re-encodes the **same** edges and terminals. But four of them touch the table format or
the search/terminal logic, so a packing or indexing bug would silently corrupt IDs:
**C1** (first-char table), **A1** (terminal/token folded into edge), **D1** (terminal bit
in `token_id`), and **R1** (fat-node format). For each, regenerate the `.mem` files from
the updated [vocab_parser.py](tokenizer-csr/vocab_parser.py) and re-run the full xsim
golden-vector check against HuggingFace `bert-base-uncased` (not just the pangram) —
include long words that exercise root→continuation backtracking, the `[UNK]` path, and
the 32-char `word_too_long` boundary, since those are where a layout bug would hide.

Per the project's toolchain rule, keep this to Vivado/xsim and don't hand-edit the
canonical `.mem` files — let the generator produce them.
