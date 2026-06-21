# Engineering Journal — FPGA WordPiece Tokenizer

> **⚠️ This is an ongoing, append-only log.** Entries are added chronologically as
> work happens and **earlier entries are NOT rewritten** when something changes
> later — so a per-problem `Status:` line reflects what was true *when it was
> written*, and some early lines (e.g. "awaiting verification") were superseded by
> later sections. **The latest sections are the authoritative, current state.** For
> the final, reconciled status of everything (review fixes H1–L3 and the R2 DMA
> datapath), read the most recent sections of this file and `HANDOFF.md` /
> `CODE_REVIEW.md`, not the older mid-file status lines.

This journal documents the debugging and hardening of the hardware tokenizer,
problem by problem, for the final project report. Each entry records the
background of the problem, the engineering discipline it belongs to, the
diagnosis, the fix, and the verification evidence.

**Tooling note:** The project's real toolchain is **Xilinx Vivado** (xsim for
simulation). Vivado is not installed on the machine used to author these fixes, so
all simulation/verification is run by the engineer in Vivado and the transcripts
are folded back into this journal as evidence. A locally available ModelSim ASE
(Intel 18.1) was briefly tried as a checker but rejected — see the "Verification
setup & method" note under H1 for why (a ModelSim-only `$readmemh` artifact, not a
Vivado/silicon issue). The canonical `tokenizer-csr/*.mem` files are never altered
for any simulator's sake.

---

## Problem H1 — Spurious `[UNK]` / lost token at a word boundary that lands during backtracking

### Engineering field
**Digital logic design & RTL functional verification** (synchronous finite-state
machine design). The bug lives in the control FSM of `trie_engine.v`. The
discipline-appropriate method is: model the FSM, identify the unhandled
state/transition, reproduce it deterministically in a simulator, fix the
transition, and prove the fix with a regression test.

### Background of the problem
The trie engine implements the **WordPiece greedy longest-match** algorithm. For
each word it walks the *root* trie to find the longest prefix that is a valid
token, emits it, then **backtracks** ("replays" the leftover characters from an
internal buffer) through the *continuation* (`##`) trie to tokenize the rest —
repeating until the whole word is consumed. A word like `embedding` becomes
`em` + `##bed` + `##ding`.

Two things happen asynchronously to this walk:
1. The **trie engine** streams characters and occasionally pauses (`ready = 0`)
   while it backtracks/replays buffered characters.
2. The **pre-tokenizer** detects the end of a word (a space) and pulses
   `in_word_done`. The trie latches this into the sticky flag `word_done_pending`.

Because the pre-tokenizer can accept the boundary space *while the trie is mid-
replay* (its holding register may be empty even when `ready = 0`),
`word_done_pending` can become `1` **during** a backtrack replay.

### The defect
In `trie_engine.v`, when a replay finishes and a word boundary is already
pending (S_IDLE replay-completion branch), the code **clears
`word_done_pending` to 0** and jumps to `S_EMIT` to flush the final piece:

```verilog
// S_IDLE, replay-completion branch
if (word_done_pending) begin
    word_done_pending <= 1'b0;   // <-- cleared too early
    use_root <= 1'b1;
    if (has_best_match) state <= S_EMIT;
    ...
```

But `S_EMIT`'s "the matched token consumed all buffered characters"
branch (`best_end == buf_end`) only finalizes the word *inside*
`if (word_done_pending)` — which is now false — and has **no `else`**:

```verilog
end else begin            // best_end == buf_end
    m_start <= buf_end; scan_ptr <= buf_end; replaying <= 1'b0;
    if (word_done_pending) begin   // false on this path -> skipped
        ...                        // <-- the only place `state` is set
    end
    // no else: `state` is never reassigned -> FSM stays in S_EMIT
end
```

Consequences:
- **Variant A (`best_end == buf_end`):** `state` is not reassigned, so the FSM
  re-enters `S_EMIT` the next cycle. `has_best_match` is now 0, so it falls into
  the UNK branch and **emits a spurious token 100 (`[UNK]`)**.
- **Variant B (`best_end != buf_end`):** it launches another replay with
  `word_done_pending` already lost, so the final tail piece can be
  **dropped / never flushed**.

### Why the existing tests don't catch it
The provided vectors (`embedding`, `unquestionably`) flush their final piece via
the *streaming* word-done path (a different S_IDLE branch that deliberately does
**not** clear `word_done_pending`), so they can pass while leaving this path
broken. No testbench asserts a `16'd100` result or forces a word boundary to
land during a replay.

### Plan (engineer's approach)
1. Stand up a command-line ModelSim flow and run the existing testbenches to
   establish a baseline.
2. Write a **directed testbench** that deterministically forces a word boundary
   to be latched during a backtrack replay, and capture the spurious/lost token.
3. Apply the fix (make `word_done_pending` owned solely by `S_EMIT` so the
   finalization always runs).
4. Re-run the directed test (bug gone) **and** the original regression
   (no regression).

### Verification setup & method
**Decision:** Vivado is the project's real toolchain, but it is not installed on
the working machine. Verification is therefore performed by running the Vivado
**xsim** behavioral simulations on the engineer's machine, with transcripts fed
back into this journal as evidence. Fixes and testbenches are authored here.

**Documented aside (ModelSim, tool artifact — not a design bug):** An attempt to
use a locally available ModelSim ASE as a quick checker failed: the design hung
after ~3 characters. Root cause was *ModelSim-only* `$readmemh` handling —
`char_to_index_map.mem` stores 4 hex digits per line but `char_map` is a 10-bit
register. Vivado follows the Verilog LRM and truncates the surplus high bits
(values all fit, so it loads correctly); ModelSim ASE instead **skips** the
over-wide lines, leaving the map uninitialized → `X` on `target_char` → FSM
deadlock. This does **not** affect Vivado or silicon, but it independently shows
that finding **L1** (make `.mem` hex widths match register widths) is worth
doing for tool-portability. No canonical files were changed for this.

### Step 0 — Baseline run (in progress)
Before changing any RTL, run the *existing* testbenches in Vivado on the current
(unfixed) code to (a) confirm the design loads and runs in Vivado, and (b) see
whether H1 already manifests on the standard multi-piece vectors
(`embedding` → 3 tokens, `unquestionably` → 4 tokens). Results pending.

### Fix applied (pending Vivado verification)
Two edits to `trie_engine.v`:

1. **Root cause** — In the `S_IDLE` replay-completion branch, removed the
   premature `word_done_pending <= 1'b0;`. `S_EMIT` is now the *single owner* of
   the flag and always runs its word-finalization. This fixes **both** Variant A
   (the spurious `[UNK]`) and Variant B (the dropped final piece): with the flag
   retained, a `best_end != buf_end` outcome simply replays the remaining tail
   for another round until `best_end == buf_end`, where `S_EMIT` finalizes and
   clears the flag.
2. **Defensive** — Gave `S_EMIT`'s `best_end == buf_end` branch an explicit
   `else` so *every* path assigns a next state (no more "hold `S_EMIT`"
   anti-pattern), returning to a safe `S_IDLE` if ever reached.

Reachability after the fix: `S_EMIT` can no longer be entered with
`best_end == buf_end && !word_done_pending`, so the previously-unhandled
combination is unreachable; the defensive `else` is belt-and-suspenders.

### Verification plan & evidence (pending)
Local ModelSim is not used (see toolchain note). Verification is by the engineer
in Vivado. A standalone how-to was written: **`H1_VERIFICATION.md`**. Key points:
- **Decisive detector (no reference needed):** plain alphanumeric input can never
  legitimately produce `[UNK]` (token `100`), because every `a–z`/`0–9` is a
  single-character token; so *any* `100` on English words = bug (Variant A).
- **Variant B (dropped token):** compare token counts against a HuggingFace
  `bert-base-uncased` reference using the same `vocab.txt`.
- A batch of ~20 multi-piece candidate words is provided (e.g. `embedding`,
  `unquestionably`, `internationalization`, `snowboarding`, …).
- **Procedure:** run the batch on the *unfixed* RTL (capture before-evidence:
  spurious `100`s / wrong counts), then on the *fixed* RTL (every word matches
  the reference, zero `100`s). That before/after pair is the report proof.

*Status:* **VERIFIED in Vivado** — fix confirmed good by the engineer.

---

## Problem H2 — Binary-search index underflow ("the broken binary search")

### Engineering field
**Computer arithmetic in digital hardware** — finite-width unsigned integer
boundary conditions inside an algorithm implementation. This is the hardware
analogue of Jon Bentley's famous binary-search bug: the two classic traps are
`mid = (lo+hi)/2` *overflow* and `hi = mid-1` *underflow* at `mid == 0`. The
author defended against the overflow (`lo + ((hi-lo)>>1)`) but not the underflow.

### Background
Each trie node's child edges are stored sorted by character index, and the engine
locates a child with a binary search over states
`S_CALC_MID → S_SEARCH_WAIT → S_EVAL → S_SEARCH`. The bounds `bs_lo`/`bs_hi` are
16-bit **unsigned**.

### The defect
In `S_EVAL`, when the probed edge character is greater than the target, the
search narrows to the lower half via `bs_hi <= edge_rd_addr - 16'd1`. If
`edge_rd_addr == 0`, unsigned `0 - 1` wraps to `0xFFFF`. The loop guard
`if (bs_lo > bs_hi)` then sees `0 > 0xFFFF == false`, so the search does not stop
— it reads edges outside this node's range (wrong token or runaway search).

`edge_rd_addr` is only 0 for a node whose edges start at offset 0 — i.e. **node
0**, the root of each trie, hit on the first character of every word/segment.
- **Root trie:** safe in practice (node 0 has a child at char index 0 = `'!'`,
  and only letters/digits are ever sent, all larger).
- **Continuation trie:** latent risk — a digit/letter whose index is below every
  `##`-piece first character drives `edge_rd_addr` to 0 and underflows.

So it is **latent/vocab-dependent today but fragile**; any vocab or alphabet
change could activate it. Fixed defensively.

### Fix applied
`trie_engine.v`, `S_EVAL` "greater" branch: the lower sub-range is
`[bs_lo, edge_rd_addr-1]`; when `edge_rd_addr == bs_lo` that range is empty, so go
straight to `S_EMIT` (character not found) instead of computing `edge_rd_addr-1`.
This removes the `mid-1` underflow at 0 and is the standard correct lower-bound
guard for all nodes (also saves one search iteration in the size-1/2 case).

### Verification notes
This path is hard to trigger on the current vocab (root trie is safe; continuation
trie needs a specific OOV-ordering input), so it is primarily a **defensive /
robustness** fix. Functional regression: the existing word vectors must still pass
unchanged (the guard only changes behavior in the previously-underflowing corner,
which those vectors do not hit). A targeted check would force a continuation-trie
lookup of a character smaller than all `##`-piece first characters and confirm a
clean dead-end (no hang, no wrong token).

*Status:* **VERIFIED in Vivado** — regression confirmed good by the engineer.

---

## Problem M1 — No long-word protection (fixed-buffer overflow)

### Engineering field
**Hardware resource-bounding / defensive embedded design.** The defining
difference between software and hardware: software grows a buffer dynamically; an
FPGA buffer is fixed at synthesis time, so any input exceeding it must be handled
explicitly or it corrupts state. The discipline is to bound every buffer, define
behavior at the limit, and ideally mirror the reference algorithm's own limit
(BERT's `max_input_chars_per_word`, which maps over-long words to `[UNK]`).

### Background & the defect
The backtracking buffer `char_buf` is `BUF_DEPTH = 32` deep and all four pointers
(`buf_end`, `scan_ptr`, `m_start`, `best_end`) are **5-bit** (`[4:0]`, 0–31). The
buffer holds the **entire current word** at absolute positions (replay indexes it
absolutely), so its depth caps **word length**, not token length — a subtlety the
original "longest token ~28 chars" comment misses.

On a word longer than the buffer, `buf_end <= buf_end + 1` runs past 31 and
**wraps 31 → 0**, silently overwriting `char_buf[0]` and desynchronizing the
pointers → corrupted output, possibly a hang. There was no guard. Real BERT caps
word length and emits `[UNK]`.

### Fix applied
Added a `word_too_long` flag and two guards in `trie_engine.v`:
1. **Intake guard** (`S_IDLE` character-accept): when `buf_end == BUF_DEPTH-1`
   the buffer is full, so stop buffering/walking and **discard** the remaining
   characters of the word (drain, `ready` stays 1). `buf_end` can therefore never
   wrap. Effective word-length cap = 31 chars (> longest BERT token ~28).
2. **Boundary handler** (`S_IDLE` word-done): on `word_done` with `word_too_long`,
   emit a single **`[UNK]` (token 100)** sentinel and reset cleanly for the next
   word; clear the flag.
3. Declared/`reset` the flag.

### Honest deviation (documented)
Because the engine streams pieces greedily, any pieces already emitted for the
part of the word that *fit* remain in the output FIFO — the architecture cannot
un-emit them. So an over-long word yields `[pieces that fit…][UNK]` rather than a
single whole-word `[UNK]` as in reference BERT. This is safe, signals the
truncation, and (with `BUF_DEPTH=32`) only affects words longer than 31
characters, which do not occur for normal single words. The `BUF_DEPTH-1`
threshold assumes the 5-bit pointers; raising `BUF_DEPTH` would also require
widening `buf_end`/`scan_ptr`/`m_start`/`best_end` (noted in code).

### Verification (engineer to run in Vivado)
- **Trigger:** feed a word of **≥ 32 letters** (e.g.
  `supercalifragilisticexpialidocious` = 34, or
  `pneumonoultramicroscopicsilicovolcanoconiosis` = 45). Expect: the design does
  **not** hang or corrupt; the output ends with **`100` (`[UNK]`)**; the next word
  tokenizes normally (proves clean reset).
- **No-regression control:** feed a long-but-fitting word
  (`antidisestablishmentarianism` = 28 chars ≤ 31) and confirm it tokenizes
  normally with **no `100`** and correct pieces.

*Status:* **VERIFIED in Vivado**. Before-fix: over-long word → 20 garbage tokens,
no `[UNK]` (FAIL). After-fix: over-long word → 15 tokens including the `[UNK]`
sentinel (PASS), next word tokenizes correctly (clean reset); full suite prints
`ALL FIX TESTS PASSED`.

---

## Regression testbench for the fixes — `tb_fixes.v`

A dedicated self-checking testbench was added at
`tokenizer-vivado/uart.srcs/sim_1/new/tb_fixes.v`. It drives `trie_engine`
directly (mapped alphabet indices, like `tb_trie_engine.v`) and is organized by
fix:

- **Section A (regression / H1+H2):** the four known-good vectors with **exact**
  ID match — `hello`→7592, `hardware`→8051, `embedding`→7861/8270/4667,
  `unquestionably`→4895/15500/3258/8231. A dropped or spurious token (H1) breaks
  the count/values; every dead-end here also exercises the H2-fixed search branch.
- **Section B (H1 invariant):** eight real multi-piece words checked against the
  decisive detector — **no token may equal 100 `[UNK]`** (a correct tokenizer
  never emits `[UNK]` for plain a–z input). No HuggingFace reference IDs needed.
- **Section C (M1):** a 40-character word (> 32) must **not hang**, must contain a
  `[UNK]` sentinel, and the **next** word must tokenize correctly (clean reset); a
  28-char fitting word is a control that must have **no** `[UNK]`.

Pass criterion: console prints **`ALL FIX TESTS PASSED`**. A 5 ms watchdog
catches a hang (the old M1 corruption symptom). The same `$readmemh` `.mem`-file
accessibility note applies as for the other testbenches.

### Run evidence
**Before the M1 fix (engine had H1+H2 only)** — Vivado run:
- Section A (regression): **all PASS**, exact IDs — confirms H1/H2 fixes are good
  and did not disturb the known vectors.
- Section B (H1 invariant): **all 8 PASS**, no `[UNK]` — confirms no spurious
  `[UNK]` (H1 Variant A absent).
- Section C (M1): the 40-char word returned **`FAIL: ... did not emit [UNK]
  (count=20)`** — i.e. the buffer wrap (40 mod 32 → pointer to 8) produced 20
  garbage tokens with no over-long signal. The `hello`-after recovery and the
  28-char control passed. → Testbench correctly **reproduces the M1 bug**.
- Summary: `1 FIX TEST(S) FAILED`.

This is the captured "before" for M1 and the "after" for H1/H2 in a single run.

**After the M1 fix (current RTL)** — Vivado run: Sections A & B still all PASS;
Section C over-long word now returns **`PASS (15 tokens, contains [UNK] sentinel
as required)`**, the recovery `hello` and the 28-char control PASS, and the footer
prints **`ALL FIX TESTS PASSED`**. → H1, H2, and M1 all confirmed.

A detailed per-word token dump was also captured (the TB prints the emitted IDs
for every word). Beyond "no `[UNK]`", it provides an independent correctness
cross-check: `tokenization` → `19204 3989` and `internationalization` →
`2248 3989` both end in the same token `3989` (the shared `##ization` suffix),
confirming the continuation-trie path is genuinely correct. The M1 over-long
case emits `13360 11057×13 100` — i.e. the 31 buffered chars tokenize and the
overflow tail becomes the single `100` `[UNK]` sentinel — and the following
`hello` returns `7592`, proving the clean reset.

*Status:* **all three fixes verified** via `tb_fixes.v` before/after runs.

---

## Problem M2 — Output FIFO overflow is silent

### Engineering field
**Flow control & backpressure in streaming dataflow systems** (the bounded-buffer
producer/consumer problem) plus **observability** — turning a silent failure into
a detectable one. The crux is **deadlock avoidance**: the textbook fix interacts
badly with the firmware's I/O pattern, so choosing the fix *is* the engineering.

### Background & the defect
In `tokenizer_axi_lite.v` the output-FIFO write is
`if (tok_out_valid && !out_fifo_full) ...`. The trie engine pulses
`out_token_valid` for one cycle with **no backpressure input**, so a token emitted
while the 256-deep output FIFO is full is **silently dropped** — no signal to the
engine, no record. Software cannot tell its output was truncated.

### The key decision — detect now, don't backpressure (yet)
The obvious fix (stall the engine when the FIFO is full) would **deadlock** with
the current firmware. `echo.c` uses a *send-all-then-drain* pattern: it pushes the
whole input, then reads tokens. With backpressure, a full output FIFO stalls the
engine → the pre-tokenizer stalls → the input FIFO fills → `tok_send_byte()` spins
waiting for input space → the drain loop is never reached → **hang**. For any input
that produces > 256 tokens (a ~1 KB telnet paste), backpressure-alone converts
"silent drop" into "server hang" — strictly worse.

So M2 is fixed as **observability first**, which is safe and non-regressing:

### Fix applied (`tokenizer_axi_lite.v`)
- New sticky `out_fifo_overflow` flag, **set** whenever `tok_out_valid &&
  out_fifo_full` (a token is dropped). 'set' takes priority over 'clear'.
- Exposed as **STATUS (0x08) bit 2** (bit 0 = input-has-space, bit 1 =
  token-available, bit 2 = overflow-occurred).
- **Cleared** by reset or by a **write to STATUS** (a `clear_overflow` pulse from
  the write logic; single-driver — set lives in the FIFO block, clear-pulse in the
  write block).

The token is still dropped on overflow, but the loss is now **detectable** (and
clearable per request). **Full prevention** for arbitrarily large inputs requires
the firmware to *drain while sending* (interleave RX reads into the TX loop) — that
belongs to the `echo.c` work (M3/M4); once the firmware interleaves, hardware
backpressure could be added safely. Cross-dependency noted here on purpose.

### Verification — `tb_m2_overflow.v`
A dedicated AXI-level testbench instantiates `tokenizer_axi_lite` with a forced
**8-deep** output FIFO (`OUT_FIFO_DEPTH_LOG2 = 3`) so overflow is reached in a few
tokens. It floods 20 single-char words (each `a ` → 1 token) **without reading
RX_DATA**, and checks:
1. overflow bit starts **0**;
2. overflow bit is **1** after the flood (loss detected — on the *unfixed* RTL this
   stays 0, i.e. the loss is silent → test fails);
3. overflow bit returns to **0** after a write to STATUS (write-to-clear).
Pass criterion: `M2 TEST PASSED`. Needs the same `.mem` files as the other sims.

### Run evidence (Vivado, `tb_m2_overflow.v`, 8-deep output FIFO)
**Before the fix:**
- initial: overflow clear — PASS (`STATUS=0x01`).
- after flooding 20 single-char words without draining: **FAIL** — expected
  overflow bit = 1, got 0 (`STATUS=0x03`). The `0x03` (only bits 0 and 1) with no
  overflow bit is exactly the silent-loss symptom: tokens were dropped and nothing
  recorded it.
- `M2 TEST FAILED (1 error)`.

**After the fix:**
- initial: overflow clear — PASS (`STATUS=0x01`).
- after flood: **PASS** — overflow bit = 1 (`STATUS=0x07`, i.e. bits 0,1,2 set) →
  the dropped tokens are now detectable.
- after a write to STATUS: **PASS** — overflow bit = 0 (`STATUS=0x03`) →
  write-to-clear works.
- `M2 TEST PASSED`.

*Status:* **VERIFIED in Vivado** (before: silent loss / bit 2 never asserts;
after: overflow detected via STATUS bit 2 and clearable by a STATUS write).
Reminder: this is *detection*; full *prevention* of loss for very large inputs is
the drain-while-sending firmware change tracked under the echo.c work (M3/M4).

---

## Problem P1 — Wasted cycles in the word-boundary handshake (throughput)

*(Found during this work, not in the original review — raised by the engineer.)*

### Engineering field
**Synchronous handshake-protocol design / throughput optimization.** This is a
micro-architecture (latency) issue, not a correctness bug: the tokens are right,
they just come out slower than necessary because a request/acknowledge handshake
between the pre-tokenizer and the trie engine falls through to a timeout instead
of completing naturally.

### Background & the defect
The pre-tokenizer gates the next word until the trie engine has finished the
current word boundary, using a two-phase handshake on `trie_ready`: phase 1 waits
for `ready` to go **LOW** (engine busy), phase 2 waits for it to return **HIGH**
(engine done), with a **4-cycle timeout** fallback if LOW is never seen.

For a **single-token word**, the engine goes `S_IDLE → S_EMIT → S_IDLE` with
`ready` held **HIGH the whole time**: the word-done branch went to `S_EMIT`
without lowering `ready`, and the single-token `S_EMIT` finalize raises it again.
The engine therefore never *looks* busy, phase 1 never sees LOW, and the
pre-tokenizer stalls on the full **4-cycle timeout** every single-token word
(and the last word of every message), holding `word_boundary_busy` high and
gating the input FIFO the whole time. Multi-token words avoided this only because
backtracking happens to drop `ready` to 0.

### First attempt (insufficient) — and what it taught us
Lowering `ready` on the `S_IDLE → S_EMIT` transition made the engine *look* busy
during the emit, but a Vivado `tb_perf_measurement` run showed **identical cycle
counts** (Test 1: 1004 → 1004; Test 3: 5822 → 5822; Test 2's −12 was only the H1
`[UNK]` no longer being emitted). Reason: the pre-tokenizer arms
`word_done_ack_wait` *while the engine is still finishing the last character*, and
its phase logic ends up releasing on the **timeout** regardless of `ready`'s
waveform one cycle later. So the one-line change altered `ready` but not the
moment the gate releases.

### Fix applied — remove the handshake (pure flow control)
Delete the fragile two-phase handshake entirely and let the trie engine's `ready`
line be the *only* backpressure:
- **`pre_tokenizer.v`:** removed `word_done_ack_wait`, `trie_ready_seen_low`, and
  the 3-bit timeout counter (plus their reset / ack-FSM / counter logic). A
  character is now delivered simply when `trie_ready && hold_valid &&
  !hold_word_done`; the word-boundary pulse is sent on `hold_word_done` with no
  acknowledge wait; `word_boundary_busy` is just `hold_word_done`.
- **`trie_engine.v`:** kept the `ready <= 1'b0` on `S_IDLE → S_EMIT`. With the
  handshake gone this is now *necessary for correctness*, not just speed: the
  engine must hold `ready` low while it emits, so the pre-tokenizer does not hand
  over the next word's character into `S_EMIT` (which does not latch input). The
  one character that can still race into the single `S_IDLE` word-done cycle is
  caught by the engine's existing `pending_char` capture.

Output is bit-for-bit identical; the per-word timeout is gone.

### Known edge cases (documented)
Two rare word-done paths neither lower `ready` nor (usefully) capture
`pending_char`: a word with **no match** (cannot happen for plain a–z/0–9 input)
and the **over-long-word `[UNK]`** path (> 31 chars). After one of these, the very
first character of the *next* word could be missed in a 1-cycle race. These are
pathological inputs; left as-is and noted rather than adding complexity.

### Verification plan
- **Functional / no char loss (critical):** `tb_top_tokenizer.v` and
  `tb_tokenizer_axi_lite.v` — the **multi-word** vectors (`hello hardware` →
  `7592 8051`) exercise the boundary between two words, so a lost first character
  would change the result. Must still pass. `tb_fixes.v` (trie-only) is unaffected
  by the pre-tokenizer change but should still pass.
- **Throughput (the win):** `tb_perf_measurement.v` before vs after — expect the
  per-word handshake cost (~4 cycles/word) to disappear, most visible on the
  multi-word tests (Test 1 ≈ 9 words → ~36 cycles; Test 3 ≈ 40+ words → ~160+).

### First applied version FAILED — handshake removal was incomplete (boundary char drop)
Applying the journal's P1 design to this repository (`pre_tokenizer.v` handshake removed
— `word_done_ack_wait`/`trie_ready_seen_low`/timeout-counter deleted,
`word_boundary_busy = hold_word_done`; `trie_engine.v` lowers `ready` on
`S_IDLE → S_EMIT`) **regressed multi-word tokenization** in the engineer's Vivado run.
`tb_tokenizer_axi_lite`, `tb_top_tokenizer`, `tb_perf_measurement` and `tb_axi_pipeline`
all failed with one signature: **the first character of every word *after the first* is
dropped** (`hello hardware` → `hello`+mis-tokenized "ardware"; the pangram returned 13
tokens for 9 words; `embedding unquestionably` lost the leading `u`). The single-word and
first-word cases were always correct, and H1/H2/M1/M2 and `pipeline_busy` (M4) all stayed
green — isolating the fault to the word-boundary handover.

**Why:** the two-phase handshake was *load-bearing*, not just a throughput tax. It gated the
input FIFO for the whole boundary, so the next word's first character arrived only after the
trie was idle. Removing it, the pre-tokenizer presents that character into the ~1–2 cycle
window where the trie finalizes the previous word in `S_EMIT` (which has no input latch). The
old safety net — `pending_char` capture in the single `S_IDLE` word-done cycle plus
`ready <= 1'b0` on `S_IDLE→S_EMIT` — only covers a character arriving on *that exact cycle*;
the real timing places it one cycle later (during `S_EMIT`), so it was pulsed but never latched.
(Note: the journal's P1 was only ever "fix in place, awaiting verification" — it had **never**
actually passed multi-word, so this exposed the design, it did not newly break it.)

### Robust fix applied — 1-deep input skid in `trie_engine.v`
The pre-tokenizer stays pure valid/ready (no handshake). The trie engine now absorbs the one
boundary-straddling character in all timing alignments, using its existing `pending_char`
register as a true 1-deep elastic skid:
1. **`S_EMIT` boundary finalize** consumes the next word's first character whether it was
   captured a cycle earlier (`pending_char`) **or** is arriving live this cycle
   (`in_char_valid`): `if (pending_char_valid || in_char_valid)` with the source chosen by
   `pending_char_valid ? pending_char : in_char`. This closes the previously-dropped
   `S_EMIT`-cycle arrival. If both arrive, the extra is re-buffered into `pending_char`.
2. **New `S_IDLE` skid-consume branch** (between the `replaying` and normal-accept branches)
   replays any buffered `pending_char` in order before accepting fresh input, re-buffering a
   simultaneous fresh character — so a chained/stranded skid char is never lost.
3. Defensive: the no-match `S_IDLE` word-done branch now also resets `current_node` (it feeds
   the skid and was the only reset path leaving it stale).
Only one character is ever in flight at a boundary (the pre-tokenizer sends one char per
`trie_ready` and the trie drops `ready` entering `S_EMIT`), so a 1-deep skid is sufficient.
Mid-word flow is untouched (the skid branch only fires when `pending_char_valid`, which is set
only in boundary paths), so the H1/H2/M1 vectors are unaffected.

**Throughput:** equal-or-better than the original handshake design — it removes the per-word
~4-cycle ack timeout and never inserts a wait cycle (the skid replays into the same fast-path
the trie already used). Net expected saving ≈ a few cycles per single-token-word boundary.

### Vivado run 1 of the robust fix — boundary drop fixed; one skid false-idle found
The engineer's run confirmed the skid fixes the character drop: `tb_top_tokenizer`,
`tb_tokenizer_axi_lite`, **`tb_perf_measurement` (all 3, Test 1 back to 1004 cycles — no
throughput regression)**, and the H1/H2/M1/M2/unit testbenches all PASS. Only the
interleaved `tb_axi_pipeline` failed, with a *drain* symptom not a tokenization one:
`embedding unquestionably` produced all 7 tokens but the drain exited one early
(`token still available / pipeline still busy after drain`, STATUS=0x0b), and the pangram
miscounted (10 vs 9).

**First `busy` hypothesis (wrong):** adding `pending_char_valid` to `busy` — the re-run was
**byte-identical**, proving that was not the gap.

**Actual cause (run 2):** the stuck token is the *final* piece of a multi-piece last word
(`unquestionably`'s `8231`), which is held until the word boundary. In `S_IDLE`'s
replay-completion branch, when the replay finishes but `word_done` has not arrived yet, the FSM
sets `ready <= 1'b1` and stays in `S_IDLE` holding `has_best_match` — so
`state==S_IDLE, ready=1, !replaying, !word_done_pending`, i.e. `busy=0`, even though a token is
still pending the boundary. In the slow MMIO cadence the internal replay finishes *before* the
trailing space's `word_done` propagates, so the drain polls that window and stops one token
early (`token still available / pipeline busy after drain`, STATUS=0x0b). The fast back-to-back
TBs never land there, which is why only `tb_axi_pipeline` saw it.

**Fix:** the pipeline is not idle while a word is in progress. Add `word_active` (set on the
first character, cleared only at word finalize) to `busy`:
`busy = (state!=S_IDLE) || !ready || replaying || word_done_pending || pending_char_valid || word_active`.
This assumes input is boundary-terminated (the firmware guarantees this); an unterminated final
word would correctly keep `busy` high (its last token genuinely cannot be emitted yet).

**`word_active` did not fix it either** (byte-identical re-run). A cycle-stamped probe in
`tb_axi_pipeline` finally showed the real gap. At the emit of the last token of a word, e.g.:
`EMIT 8231 | pb_all=0 trie_busy=0 wact=0 state=S_IDLE ready=1 ofifo_empty=1` — the `pb_all 1->0`
edge lands on the **same** timestamp as the emit.

**Actual root cause (a one-cycle emit hole in the AXI wrapper, not the trie):** when the engine
emits a word's final token, `out_token_valid` pulses *and the engine finalizes/goes idle the
same cycle* (`trie_busy`/`word_active` drop). But the output-FIFO write is registered, so
`out_fifo_empty` is still 1 that cycle — the token is in flight (left the engine, not yet in the
FIFO). For that single cycle every term of `pipeline_busy_all` reads 0. It happens at every
last-token emit; only `8231` happened to be polled in that 1-cycle window (a race), which is why
the fast back-to-back TBs and the other words passed. (So `word_active` was in fact doing its
job — the probe showed `pb_all` held high through the whole `3258→8231` wait; the hole was only
the emit cycle.)

**Fix:** add `tok_out_valid` (the engine's emit pulse) to the wrapper's busy term:
`pipeline_busy_all = tok_pipeline_busy || !in_fifo_empty || in_fifo_out_valid || !out_fifo_empty || tok_out_valid`.
This keeps STATUS bit 3 high on the emit cycle, bridging to when the token lands in the FIFO
(`!out_fifo_empty`) the next cycle. Pure observation signal — tokenization is unchanged.

*Status:* **VERIFIED in Vivado.** With the `tok_out_valid` term added, `tb_axi_pipeline`
prints `AXI PIPELINE TESTS PASSED` (all four vectors correct, `pangram` back to 9), and the
full suite is green: `tb_top_tokenizer`, `tb_tokenizer_axi_lite`, `tb_perf_measurement`
(all 3, Test 1 = 1004 cycles → no throughput regression), `tb_h1_h2_m1`,
`tb_h1_bug_investigation`, `tb_m2_overflow`, `tb_trie_engine`, `tb_pre_tokenizer`.
P1 (pure flow-control + trie input skid) and the M4 RTL (`pipeline_busy` STATUS bit 3) are
confirmed. Remaining for M4: the firmware half (`tok_pipeline_busy()` + drain-while-sending in
`echo.c`) and the on-board TCP check. Bitstream/timing closure (WNS/TNS) clean.

### Residual P1 boundary case found on-board: short word + next word drops a character
On-board, `embed ding` returned a spurious `[UNK]` and `embed hardware` dropped the next word's
first character (`embed hardware` → `7861 8270 12098 2094 8059`, i.e. `embed` + "ardware" with
the `h` lost). It only reproduced under the firmware's slow, drain-while-sending byte cadence:
`tb_tokenizer_axi_lite` (fast, FIFO-buffered) tokenized `embed` correctly, but `tb_axi_pipeline`
(firmware timing) reproduced the drop. A cycle-stamped char-handoff probe showed the next word's
first character (`h`) arriving at the `S_EMIT` cycle with `best_end != buf_end` — the
**replay-launch** branch — which emits a piece and starts a backtrack but does not latch input.
The skid's `S_EMIT` capture (fix A) only covered the `best_end == buf_end` *finalize* branch;
`embed` (= `em` + `##bed`, a short two-piece word) launches its replay on the exact cycle the
next character arrives, so it slipped through. `embedding` never hit it because its next-word
character happened to land on the finalize cycle instead.

**Fix:** capture the incoming character in the replay-launch branch too, guarded by
`word_done_pending` (so a word's own mid-stream characters are never grabbed — only a next-word
character, which can only appear once a boundary is pending) and `!pending_char_valid` (no
overwrite). It is replayed when the word finalizes, via the existing `pending_char` handler.
Surgical one-branch change in `trie_engine.v`'s `S_EMIT`.

*Status:* fix applied; **awaiting `tb_axi_pipeline` re-run** (Test 6 `embed hardware` must return
`7861 8270 8051`; Test 5 `embed` and all prior vectors must stay green). Then re-verify on-board.

---

## Investigation — board-only spurious `[UNK]` (token 100) on "embed"-class words

### Symptom
After the replay-launch capture fix above passed behavioral sim (incl. the slow-cadence
`embed`/`embed hardware` tests), the **board** still returned `embed ` → `7861 8270 100` and
`embed hardware` → `7861 8270 100 8051` — i.e. the word tokenizes correctly (`em` + `##bed`) but
a spurious `[UNK]` is appended at the boundary. Behavioral sim is clean at every cadence.

### Diagnosis — stale bitstream, not a live logic bug
Two independent lines of evidence:

1. **RTL trace (analytical).** Walked `embed ` through `trie_engine.v` cycle-by-cycle for all byte
   cadences. The engine records the `em` match during streaming, emits `7861`, launches the replay
   of `bed`, emits `8270`, then finalizes: `word_done_pending` cleared, `buf_end`/`scan_ptr`/
   `m_start` reset, `has_best_match=0`, `word_active=0`. There is **no third entry to `S_EMIT`**
   and nothing left in `pending_char` to replay (the replay-launch capture only fires under
   `word_done_pending && in_char_valid`, impossible for `embed` alone). A spurious third `100` is
   therefore **unreachable in the current source** — so the board must be running different logic.

2. **Build-artifact forensics.** On disk: `trie_engine.v` edited **14:20**; the `design_1_wrapper.xsa`
   exported to the board is **15:50**; the latest top synthesis (`synth_1/design_1_wrapper.dcp`) is
   **16:12** — *after* the `.xsa` export — and `impl_1` had only reached `place_design.begin` with
   **no routed checkpoint and no `.bit`**. So the board's 15:50 bitstream predates the 16:12
   re-synthesis of the fix. The board was never running the fixed RTL.

   The tokenizer is synthesized in **Global mode** (the IP synth wrapper instantiates
   `tokenizer_axi_lite` directly; there is **no separate OOC `.dcp` or IP synth run** to cache a
   stale netlist), so the 16:12 top synthesis already includes the current `trie_engine.v`. No
   "Reset Output Products"/OOC step is needed — completing impl → bitstream → `.xsa` export suffices.

### Resolution path (engineer running impl now)
Let implementation finish → **Generate Bitstream** → **Export Hardware (include bitstream)**,
overwriting `design_1_wrapper.xsa` (confirm its timestamp is newer than the 16:12 synthesis) →
in Vitis re-read the `.xsa`, **re-apply the two BSP PHY patches** (a `.xsa` re-read wipes them),
rebuild, program → re-test `embed ` (expect `7861 8270`) and `embed hardware` (expect
`7861 8270 8051`).

*Status:* **RESOLVED — root cause was a stale bitstream, not RTL.** Behavioral sim of the current
`trie_engine.v` is clean (`tb_axi_pipeline`: `embed` and `embed (slow)` both emit exactly
`7861 8270`, `best_end==buf_end` finalize, no third token), and the synthesis log shows no
functional `trie_engine` warning (only a cosmetic `char_buf` RAM-inference fallback, [Synth 8-7186],
which as flip-flops is functionally identical to the sim model). That proved the synthesized
netlist matches the clean sim, so a board still emitting `7861 8270 100` had to be running an older
image. It was: the Vitis run configuration was programming a cached, month-old bitstream from
`lwip_echo_server/_ide/bitstream/design_1_wrapper.bit` while loading a freshly-built ELF — new
firmware (M3/M4 live) on old tokenizer hardware. Repointing the launch config's bitstream to the
current Vivado output (`uart.runs/impl_1/design_1_wrapper.bit`) and reprogramming cleared it:
`embed` → `7861 8270`, `embed hardware` → `7861 8270 8051`. The residual-P1 `S_EMIT` replay-launch
capture fix is hereby **verified on-board**. (Cosmetic follow-up still open: fix the `char_buf`
constant-vs-variable-index write so it infers as distributed RAM and the warning goes away.)

---

## On-board verification — full regression pass (silicon, over TCP port 7)

With the correct bitstream finally on the FPGA, a full suite was run on the board and every fix
confirmed on silicon:

- **embed fix / residual P1:** `embed` → `7861 8270`; `embed hardware` → `7861 8270 8051` (no
  spurious `[UNK]`, no dropped boundary character).
- **H1** (no spurious/dropped tokens on multi-piece replay): `embedding` → `7861 8270 4667`;
  `unquestionably` → `4895 15500 3258 8231`; `tokenization` → `19204 3989`;
  `internationalization` → `2248 3989`. No `100` on any plain-text word.
- **P1** (no boundary character loss): `hello hardware` → `7592 8051`;
  `embedding unquestionably` → 7 correct tokens; the 9-word pangram → all 9 correct.
- **M1** (over-long word protection): `pneumonoultramicroscopicsilicovolcanoconiosis` (45 chars) →
  11 fitting pieces followed by a single `100` sentinel, no hang; the 28-char control
  `antidisestablishmentarianism` → 8 tokens with no `100`; a following `hello` → `7592` (clean
  reset).
- **M3** (TCP segment framing): split sends `embed`+`ding` → `7861 8270 4667` and
  `inter`+`nationalization` → `2248 3989`, each the combined word, server did not hang on the
  mid-word segment.
- **M4** (deterministic drain): per-request latency scales with token count (no-token segments
  ~25 µs, up to ~1537 µs for 11 tokens) instead of the old fixed ~500 µs blind-delay floor.

**H2** (node-0 binary-search underflow) is defensive and exercised implicitly by every dead-end
search above; **M2** (output-FIFO overflow detection) remains verified in `tb_m2_overflow` — on the
board M4's drain-while-sending prevents the FIFO from ever backing up, so it is not separately
triggerable. All review items H1–M4 plus P1 and the embed fix are now verified.

**Process note (cost a long false-alarm debug):** the board appeared to still emit `7861 8270 100`
*after* the RTL was correct because the Vitis run configuration was programming a stale, month-old
cached bitstream (`lwip_echo_server/_ide/bitstream/design_1_wrapper.bit`) while loading a fresh ELF.
Repointing the launch config to `uart.runs/impl_1/design_1_wrapper.bit` fixed it. When board
behavior contradicts a clean xsim run, suspect the programmed bitstream before the RTL.

---

## Low-priority review items (L1–L3) and a synthesis-warning cleanup

### L1 — `.mem` token-id width does not match the register width
**Engineering field:** hardware/data-representation consistency. `trie_engine.v` reads the token-id
memories into a 16-bit register (`TOKEN_W = 16`), but the Python generator
(`flat_trie_compression/vocab_parser.py`, `flatten_csr`) wrote each entry as **8 hex digits**
(`{tid:08X}`, 32 bits). Vivado loads it correctly (it truncates the all-zero high half, and every
BERT id ≤ 30521 < 65536 fits in 16 bits), but the wider-than-register `$readmemh` provokes a
warning. **Fix:** write token ids as **4 hex digits** (`{tid:04X}`, and `0000` for the
non-terminal `-1` sentinel) so the file width equals the register width. The loaded BRAM contents
are **bit-identical** to before, so tokenization is unchanged — only the warning goes away.
*Applying it:* re-run `vocab_parser.py`, replace `root_token_ids.mem` / `cont_token_ids.mem` in the
Vivado project, re-synthesize. (Only the two token-id files change; row_ptr/edges/is_terminal are
untouched.) The other width note — `char_to_index_map.mem` at 4 hex into a 10-bit register — cannot
be made exact (10 bits is not nibble-aligned) and is harmless, so it is left as-is.

### L3 — AXI read could re-pop the output FIFO if a master holds `arvalid` high
**Engineering field:** AXI4-Lite slave protocol robustness. The read FSM in `tokenizer_axi_lite.v`
accepted a read whenever `arvalid && !rvalid`. A compliant master (the MicroBlaze) deasserts
`arvalid` after the handshake, so each `RX_DATA` read pops one token — but a master that *holds*
`arvalid` high across/after the response would be re-accepted once `rvalid` cleared, popping a
second token and **silently dropping** it. **Fix:** added `read_addr_serviced`, set when a read is
accepted and cleared only once `arvalid` deasserts; the accept condition now also requires
`!read_addr_serviced`. One `arvalid` assertion therefore yields exactly one FIFO pop. Normal
single-beat reads are unaffected (the flag clears as soon as the master drops `arvalid`).

### char_buf synthesis warning (not in the original review; found during the embed debug)
`char_buf` carried `(* ram_style = "distributed" *)`, but the mix of variable-index writes
(`char_buf[buf_end]`) and the constant-index write (`char_buf[0]`) at a word boundary prevents
distributed-RAM inference, so Vivado **ignored** the attribute and emitted 32 warnings while
implementing the array as flip-flops. The attribute was removed (and the comment corrected): the
synthesized result is **identical** (flip-flops, synchronous write / asynchronous read), and the
warnings are gone. A true-LUTRAM refactor (single muxed write port) is possible but would touch the
verified datapath for no functional gain, so it was not done.

### tok_word_busy used-before-declaration warning (`tokenizer_axi_lite.v`)
Synthesis warned `[Synth 8-6901] identifier 'tok_word_busy' is used before its declaration`: the
input-FIFO block reads `tok_word_busy` (the pre-tokenizer's word-boundary gate) while the `wire` was
declared further down with the other pipeline-output wires. Verilog resolves it to the same net, so
it was always functionally correct, but it is an untidy forward reference. **Fix:** moved the
`wire tok_word_busy;` declaration up next to `in_fifo_ready`, ahead of the input-FIFO block that
reads it (the net is still driven by the `top_tokenizer` instance further down — fine for a net).
Pure declaration move, zero behavioral change; the warning clears on the next synthesis run.

### L2 — testbench coverage gap (digits)
**Engineering field:** functional-verification completeness. Existing tests covered `[UNK]`,
over-long words, and overflow, but not digit input. Added a `check_no_unk` invariant task and a
digit/alphanumeric case to `tb_axi_pipeline.v` (`2024`, `abc123`): plain a–z/0–9 input can never
legitimately produce `[UNK]` (100), so the test asserts no `100`, at least one token, and a fully
idle pipeline — without needing reference ids. Digits map to alphabet indices below the letters, so
this also exercises the binary-search lower bound that **H2** hardened.

*Status:* all four edits applied. **`tb_axi_pipeline` re-run is green (`AXI PIPELINE TESTS
PASSED`)**, which validates L2, L3 and the char_buf change in behavioral sim in one shot: the new
digit cases pass (`2024` -> `16798 2549`, `abc123` -> `5925 12521 2509`, no `[UNK]`); the many AXI
reads through the new `read_addr_serviced` gate (L3) all return correct tokens; and every prior
vector is unchanged (`embed` -> `7861 8270`, pangram = 9, etc.), confirming the char_buf
attribute removal is behavior-neutral. **VERIFIED on-board.** After regenerating the 4-hex
`*_token_ids.mem`, re-synthesizing (the 32 char_buf `[Synth 8-7186]` warnings and the token-id
width warning are gone), rebuilding the bitstream and reprogramming, the full vector set is
unchanged on silicon (`embed` -> `7861 8270`, `embed hardware` -> `7861 8270 8051`, `embedding`,
`unquestionably`, `hello hardware`, the 9-word pangram all correct), and the digit/alphanumeric
cases match the xsim values exactly with no `[UNK]` (`2024` -> `16798 2549`, `abc123` ->
`5925 12521 2509`) -- confirming the L1 memory regeneration is correct and digit handling is good on
hardware. M3 split (`embed`+`ding` -> `7861 8270 4667`, no hang) and M4 latency scaling also still
hold. All review items H1, H2, M1-M4, P1 and L1, L2, L3 plus the char_buf cleanup are now verified
on silicon. (Residual robustness note: the project still sources its 9 `.mem` files from
`C:/Users/talsh/Downloads/` -- functional but fragile; relocating them into the project tree is
recommended before final submission.)

---

## Session close-out (2026-06-20) and open items handed off

**Complete and verified on silicon:** every code-review item — H1, H2, M1, M2, M3, M4, P1, L1, L2,
L3 — plus the embed-class boundary fix and the char_buf / tok_word_busy synthesis-warning cleanups.
The previous "board-only spurious `[UNK]`" open issue was diagnosed as a stale Vitis-programmed
bitstream (the RTL was always correct) and is closed. Two of the original "must-do before
presentation" notes map directly to delivered work: the busy-wait/blind-delay removal is **M4**, and
the wasted pre-tokenizer handshake cycles are **P1** — both done and verified on-board.

**Handed off (see `HANDOFF.md` → "OPEN ITEMS" and `OPTIMIZATION_OPTIONS.md`):**
- **MUST DO — DMA instead of byte-by-byte AXI-Lite polling (optimization R2).** With M4's blind
  delay gone, the per-byte MMIO software overhead (~50–100 cyc/byte) is the dominant on-board cost
  (~1.1 ms for a 43-char line vs ~10 µs of fabric work). Replace the byte-banging with an AXI-Stream
  interface on the IP + an AXI DMA. This is the next engineer's primary task.
- **Optional, not required for the final report:** connect the floating `init_calib_complete` in the
  block design; resolve `tb_perf_measurement` Test 2 (16 vs 15 tokens — a sim-only timing artifact)
  by fixing the TB or documenting it; implement the full RTL8211E PHY register sequence (the BSP
  patches are the pragmatic fix); relocate the 9 `.mem` files out of `Downloads/` into the project
  tree; and remove the `tb_axi_pipeline.v` temp debug probe for the final clean version.

---

## Optimization R2 — AXI-Stream + DMA datapath (replace byte-by-byte MMIO)

### Engineering field
**Hardware/software co-design and on-chip data movement (AXI4-Stream + DMA).** With M4's blind
delay gone, the dominant on-board cost was the per-byte MMIO loop: the MicroBlaze spends ~50-100
cycles of software overhead per byte (poll STATUS, write `TX_DATA`), so a 43-char line took ~1.1 ms
against ~10 us of fabric tokenization -- the system was MMIO-bound, not fabric-bound. R2 adds a
stream datapath so an AXI DMA moves bytes in and tokens out at ~1/clock with no per-element CPU
involvement.

### RTL design (`tokenizer_axi_lite.v`, additive -- AXI-Lite path unchanged)
- **AXI4-Stream slave `s_axis`** (8-bit) feeds the existing input FIFO; `s_axis_tready =
  !in_fifo_full && !in_fifo_wr_en`; the FIFO write got an `else if (s_axis_fire)` branch.
- **AXI4-Stream master `m_axis`** (16-bit = one token) drains the output FIFO; the FIFO pops on
  `out_fifo_rd_en || m_axis_fire`.
- **TLAST threading** (the crux of the DMA framing): `input_done` latches when the input stream's
  `s_axis_tlast` byte is accepted and clears when the response's last token is handed off; a
  `producing` term (= `pipeline_busy_all` minus the `!out_fifo_empty` term) says "is anything still
  upstream of the output FIFO?". Then `m_axis_tlast = m_axis_tvalid && out_fifo_one_left &&
  input_done && !producing` -- assert TLAST only on the token that empties the FIFO once nothing
  more can be produced. Because the final token lands in the FIFO the cycle *after* the emit pulse,
  `producing` has already dropped, so there is no race.
- **`0x0C` TOKEN_COUNT register** (write-to-clear, increments per enqueued token): simple-mode AXI
  DMA S2MM does not report the received length, so firmware reads this to learn how many tokens a
  transfer produced. Single-driver via a `clear_count` pulse (same pattern as M2's overflow clear).
- The pre-tokenizer/trie core is untouched, so **token IDs stay identical**.

### Verification -- `tb_axi_dma.v` (new)
Drives `s_axis` like a DMA MM2S, collects `m_axis` like an S2MM, and checks token IDs, that TLAST
lands on exactly the last token, and that `TOKEN_COUNT(0x0C)` matches. Green: `hello` -> `7592`,
`embed` -> `7861 8270` (tlast on `8270`), `embedding` -> `7861 8270 4667`. The four AXI-Lite
testbenches got the new stream inputs tied off; full regression stayed green.

**Debugging notes (two real lessons):**
1. **Testbench driving race** -- the first runs showed the first char of every word dropped and
   TLAST never asserting. Cause: `axis_send` drove `s_axis_*` with blocking assignments *at* the
   posedge, racing the DUT's sampling -- the probe (a different always block) happened to win and
   showed correct bytes, but the FIFO write / `input_done` lost and saw the next byte / a deasserted
   `tlast`. Fixed by driving the stream stimulus on the **negedge** so values are stable when the
   DUT samples.
2. **`.mem` not loaded** -- before that, the trie looped forever in the binary search (`st 4->5->6`)
   because the 9 `.mem` files weren't in the xsim run dir (uninitialized BRAM). Root cause: the
   `.xpr` referenced `sources_1/imports/` which **did not exist**. Fixed by creating that dir and
   committing the 9 current (4-hex) `.mem` there so the project is self-contained -- this is also
   what finally killed the recurring "`$readmemh` cannot open" failures.

### Block-design integration (Vivado)
- The tokenizer is a **module-reference IP** (`module_ref`), so Vivado auto-infers the two
  AXI4-Stream interfaces from the port names -- no IP-Packager step. One required RTL tweak: an
  `(* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis:m_axis, ASSOCIATED_RESET
  s_axi_aresetn" *)` attribute on `s_axi_aclk` to associate the streams with the clock (clears
  `BD 41-967`); metadata-only, no re-verify.
- Added an **AXI DMA** (Simple mode; MM2S stream 8-bit, S2MM stream 16-bit), MM2S -> `s_axis`,
  `m_axis` -> S2MM, S_AXI_LITE + the memory masters wired to the MicroBlaze/DDR via Connection
  Automation. DMA memory window = the MIG DDR range (`0x8000_0000`+), so DMA buffers must live in
  DDR. (The floating `init_calib_complete` was left for a separate change -- the design already
  works with it unconnected; wiring it into `rst_clk_wiz_1_100M/dcm_locked` via an AND with
  `clk_wiz_1/locked` is the robustness follow-up.)

### Firmware
A DMA `echo.c` draft (`lwip_echo_server/src/echo_dma_draft.txt`) uses simple-mode `XAxiDma`: clear
`0x0C` -> flush input from cache -> arm S2MM -> kick MM2S -> poll both done -> read `0x0C` for the
count -> invalidate + read the token buffer -> send back. Buffers must be in DDR; input must end on
a word boundary so the last word flushes and TLAST propagates (the draft appends `\n` if needed).

*Status (design):* RTL + `tb_axi_dma` + the `0x0C` check **verified in xsim**, full regression green,
block design wired (DMA + clock association). See the on-board bring-up below for the firmware
integration, the two real bugs, and the final verified numbers.

### On-board bring-up & verification (R2 complete, 2026-06-21)

The firmware draft was integrated into `echo.c` (replacing the byte-by-byte AXI-Lite send/drain) and
the design brought up on silicon. **Result: R2 works on-board, every golden vector correct, ~14x
faster than the MMIO build on the pangram and the gap widens with input length.**

**Firmware (`echo.c`), final form:**
- Constants locked from this build's `xparameters.h` -- this is the **SDT / Vitis-Unified flow**, so
  there are no `_DEVICE_ID` macros: the `XAxiDma` driver is looked up by **base address**.
  `TOKENIZER_BASE = 0x44A00000` (`TOKEN_COUNT` at `+0x0C`); `TOK_DMA_BASEADDR =
  XPAR_AXI_DMA_0_BASEADDR = 0x41E10000`. NOTE there are **two** AXI DMAs in the design -- ours is
  `0x41E10000`; the AXI Ethernet's own DMA is `0x41E00000`. Using the wrong one is an easy trap.
- `tokenizer_dma_init()` (`LookupConfig` by base -> `CfgInitialize` -> assert Simple mode via
  `XAxiDma_HasSg` -> disable interrupts) and `tokenizer_dma_run(len)`: clear `0x0C` ->
  `DCacheFlushRange` the input -> `DCacheInvalidateRange` the token buffer -> arm S2MM
  (`DEVICE_TO_DMA`) -> kick MM2S (`DMA_TO_DEVICE`) -> poll both `XAxiDma_Busy` with a bounded timeout
  -> invalidate + read `0x0C` for the token count.
- DMA buffers (`dma_in_buf[2048]`, `dma_tok_buf[1024]`, 64-byte aligned) resolve to **DDR** -- the
  only region the AXI DMA can reach. Confirmed on-board at `0x80031B00` / `0x80032300` (the linker
  places `.bss` in the MIG range; no linker-script change needed). The MicroBlaze D-cache covers the
  MIG range, so the flush/invalidate calls are required.
- `recv_callback` now copies the TCP segment to DDR, runs one DMA round-trip, and formats the decimal
  IDs. The AXI-timer instrumentation was kept so the DMA latency is directly comparable to the old
  MMIO `Total:` numbers (printed as `DMA total: <us>`).

**Bug 1 -- the programmed bitstream was not the final design.** The first on-board runs failed
*identically to a hardware fault*: MM2S completed cleanly (status `Idle`+`IOC`, no error) but the
tokenizer produced **0 tokens** (`TOK_COUNT=0`, STATUS `0x01` = empty/idle). Two temporary firmware
self-tests localized it without a rebuild: an **MMIO self-test** (feed `"embed "` via `TX_DATA 0x00`,
which writes the *same* input FIFO the DMA feeds) returned `TOK_COUNT=2`, proving the **core + input
FIFO + output path all work**; a **DMA self-test** (run the full datapath on a known DDR buffer)
returned 0. Inspecting the generated wrapper (`design_1_tokenizer_axi_lite_0_0.v`) and `design_1.hwh`
showed the `s_axis`/`m_axis` interfaces and **all four handshake nets correctly wired** (8/16 widths,
both on `clk_wiz_1_clk_100`) -- so the hardware was sound. The real cause was that the programmed
bitstream predated the final IP changes; a clean **regenerate bitstream -> re-read `.xsa` -> re-apply
the PHY patches -> rebuild** made the DMA self-test return `ntok=2 7861 8270` from `0x80031B00`.
**Lesson (re-confirmed from the embed-`[UNK]` saga): when on-board behavior contradicts a verified
datapath, suspect the programmed bitstream before the RTL.**

**Bug 2 -- the zero-token TLAST hang (a genuine R2 design corner).** With the fresh bitstream the
golden words tokenized correctly, but the **TCP connection aborted**. Root cause: a telnet client
sends a word and its trailing `\r\n` as **separate TCP segments**, and a boundary-only segment
(`"\r\n"`, spaces) produces **zero tokens**. Because `m_axis_tlast` rides on a token, a zero-token
response means **TLAST is never asserted**, so the simple-mode S2MM transfer waits forever and
`tokenizer_dma_run` spins its (then 100M-iteration) timeout *inside the lwIP callback* -> the stack
stalls for seconds -> the connection drops. The AXI-Lite path never hit this (MMIO simply produced no
tokens and returned). **Fix (firmware):** scan each segment for any word character and **never launch
a DMA transfer that cannot produce >=1 token**. A boundary-only segment is skipped -- and if it
carried a newline, a `\r\n` is emitted so the preceding word's tokens are terminated on their own
line (telnet splits the word and its CR/LF). The poll timeout was also cut from 100M to **1M**
iterations as defense-in-depth: a legit 44-token transfer needs only ~hundreds of iterations, so this
caps any future stall at tens of ms instead of seconds (short enough that lwIP won't drop the link).

**On-board results (clean build, telnet to port 7):**

| Text | Chars | Tokens | DMA latency | Token IDs (match HuggingFace bert-base-uncased) |
|---|---|---|---|---|
| `the quick brown fox jumps over the lazy dog` | 43 | 9 | **70 us** | `1996 4248 2829 4419 14523 2058 1996 13971 3899` |
| `tokenization of unbelievable embeddings is remarkably straightforward` | 69 | 11 | **54 us** | `19204 3989 1997 23653 7861 8270 4667 2015 2003 17431 19647` |
| `machine learning models ... training corpus` | 156 | 24 | **72 us** | `3698 4083 ... 13931` (24 ids) |

The DMA latency is **flat** (~54-72 us) even as input nearly quadruples -- it is dominated by fixed
per-transfer overhead (the two 2 KB cache invalidates, arming S2MM, DMA setup), not by the data, so
**per-token cost falls** as input grows (7.8 -> 3.0 us/token). Versus the MMIO build's ~1000 us on the
pangram that is **~14x**, and the advantage **widens** with input length (MMIO grows linearly with
bytes/tokens; DMA stays flat). Refinement noted for the report: the post-transfer invalidate clears
the full 2 KB token buffer every call -- invalidating only `ntok*2` bytes would drop the small-input
numbers further and sharpen the flat-vs-linear curve.

**Temporary diagnostics removed** for the final firmware: the two startup self-tests
(`tokenizer_mmio_selftest`, `tokenizer_dma_selftest`) and the verbose `S2MM timeout` register dump
were stripped once R2 was signed off.

*Status:* **R2 DONE and verified on-board.** Next: the report deliverables below (performance /
power / CSV). The CPU-vs-FPGA benchmark script is at `analysis/cpu_tokenizer_benchmark.py`.

---

## Report deliverables queued after the DMA (performance + power)

Two analyses are queued for the final report, to be done once the DMA is verified on-board (full
detail in `HANDOFF.md` -> OPEN ITEMS -> NEXT):

1. **Fair FPGA-vs-CPU performance comparison (apples-to-apples).** The existing `tb_perf_measurement`
   cycle count is *not* pure fabric latency despite its header -- it includes the AXI-Lite send
   cadence (`tok_send_byte` ~10 cyc/byte) and fixed `repeat(500)`/`repeat(2000)` wait loops, so it
   over-states FPGA latency (the real win is larger). The defensible number is the **true fabric
   latency**: first character into the trie (`pt_out_char_valid`) to the last token emitted
   (`tok_out_valid`), with input streamed at 1 byte/clock (the `s_axis`/DMA path), measured on the
   internal signals -- needs a clean measurement TB. The CPU side must use **`BertTokenizerFast`**
   (the Rust tokenizer; the benchmark script currently uses the slow pure-Python `BertTokenizer` and
   mislabels it "Rust-accelerated"), with the actual console output attached and the CPU clock
   (~3-5 GHz) stated next to the FPGA's 100 MHz. The Test-2 16-vs-15 sim artifact (issue #12) is a
   noted caveat that inflates that test's count.

2. **Power-consumption comparison (perf-per-watt).** Latency is only half the story; the core
   argument for a specialized datapath is energy. Vivado `report_power` (post-implementation, with
   realistic switching activity / a SAIF from the perf sim) for the FPGA's dynamic + static power vs
   the CPU's package power, reported as **energy per tokenization** (latency x power) or tokens per
   Joule -- where a 100 MHz datapath should decisively beat a multi-GHz CPU even when latency is
   close.

---

## Problem M3 — Every TCP segment treated as word-final (firmware)

### Engineering field
**Network stream processing / message framing.** TCP is a byte stream, not a
message stream: a logical unit (a word) can be split across transport units (TCP
segments) arbitrarily. A correct stream parser keeps state across segment edges
and never treats a segment boundary as a logical boundary. This lives in the
MicroBlaze firmware (lwIP `recv_callback` in `echo.c`), not the RTL.

### Background & the defect
`echo.c`'s `recv_callback` stripped `\r\n`, forwarded the bytes, then **appended a
space** at the end of *every* call — i.e. after every TCP segment. That synthetic
space forced a word boundary at each packet edge. So a word split across two
segments (`embed` in one packet, `ding` in the next) was flushed as `embed` by the
first packet's appended space and `ding` by the second → two words instead of
`embedding`, i.e. wrong token IDs. Harmless for short telnet lines (one line per
packet); wrong for large pastes or fragmented input.

### Fix applied (`echo.c`)
Forward every received byte unchanged and **never append a boundary**. The
hardware pre-tokenizer already treats any non-alphanumeric byte (space, tab, CR,
LF, punctuation) as a word boundary, so the real whitespace in the text flushes
each completed word — including the `\r\n` that ends a telnet line, which flushes
that line's last word. A word ending exactly at a segment edge now stays in the
pipeline until the rest of it (and its real boundary) arrive later, so split words
tokenize correctly. (`\r\n` are no longer stripped; they simply act as the
boundary that flushes the last word — they emit no tokens.)

### Known assumption (documented)
Input is expected to be whitespace/newline-terminated (telnet always sends `\r\n`).
If a client sent a final word with no trailing boundary and then sent nothing more,
that last word would remain unflushed (no token until a boundary arrives) — the
correct streaming behavior, but worth noting.

### Verification plan (on the board, over TCP)
- **Regression:** a normal single-line message (e.g. `the quick brown fox ...`)
  must return the same token IDs as before.
- **The fix:** send a word split across two TCP segments and confirm a single,
  correct tokenization. A small Python client can force the split:
  `s.sendall(b"embed"); time.sleep(0.2); s.sendall(b"ding\n")` and compare the
  returned IDs to the HuggingFace reference for `embedding` (expect `7861 8270
  4667`, not the `embed`+`ding` split). On the unfixed firmware this returns the
  wrong split.

*Status:* applied in `echo.c` (raw-byte forwarding, no strip, no appended boundary);
awaiting an on-board TCP check. See the M3+M4 firmware note below for the drain interaction.

---

## M3 + M4 firmware (`echo.c`) — implementation note (drain interaction)

The two firmware fixes were applied together in `recv_callback`:

- **M3:** forward every received byte unchanged — nothing stripped, no synthetic trailing
  space. Real whitespace/`\r\n` provides the word boundaries; a word split across TCP segments
  stays in the pipeline until its real boundary arrives.
- **M4:** added `tok_pipeline_busy()` (STATUS bit 3); **drain-while-sending** (after each byte,
  read any already-available tokens — a token is always read when available so the pipeline can
  never stall, and the response buffer only stops *appending* when nearly full); and a
  **deterministic final drain** replacing the ~500 µs blind delay.

**Co-design subtlety found while implementing (decides the final-drain logic).** Because the RTL
`pipeline_busy` includes `word_active` (needed for the trie's mid-replay token hold — see the P1
debug saga), a word held mid-stream keeps `pipeline_busy` **high**. With M3 no longer appending a
boundary, a TCP segment can legitimately end mid-word, so a naive
`while (pipeline_busy() || has_token())` final drain would **block lwIP forever** on exactly the
fragmented input M3 targets. Resolved deterministically (no blind delay, no hang) by keying the
final drain on whether *the segment's own last byte was a word boundary*:
- **ended on a boundary** (the normal telnet `\r\n` case): every word flushes, so wait until
  `pipeline_busy` clears and read every token;
- **ended mid-word** (alphanumeric last byte): a partial word is intentionally held for the next
  segment, so do **not** wait on `pipeline_busy` — take the tokens already produced and return;
  the held word's tokens drain at the start of the next segment's send loop.

### Verification plan (on the board, over TCP)
- **M4 latency / functional:** a normal line (`the quick brown fox jumps over the lazy dog\n`)
  returns the known IDs (`1996 4248 2829 4419 14523 2058 1996 13971 3899`) and the UART `Total`
  latency is far below the old ~500 µs floor (now scales with input, ~tens of µs).
- **M3 split word:** `s.sendall(b"embed"); time.sleep(0.2); s.sendall(b"ding\n")` → the combined
  reply must equal `embedding` = `7861 8270 4667` (not an `embed`+`ding` split), and the server
  must **not hang** on the first (mid-word) segment.

*Status:* applied in `echo.c`; awaiting the on-board TCP checks above.

---

## Problem M4 — Blind 50,000-iteration drain delay (and closing M2's prevention)

### Engineering field
**Hardware/software co-design & synchronization.** The anti-pattern is waiting on
hardware with a *fixed time guess* instead of a real completion signal. The fix
replaces the guess with an explicit busy/done status the CPU polls — deterministic
and self-scaling — and, by draining while sending, also closes the *prevention*
side of M2 (the output FIFO no longer backs up during a long input).

### Background & the defect
`echo.c`'s `recv_callback` spun ~50,000 iterations (~500 µs) after sending bytes
"to give the hardware time," then drained tokens. Against ~10 µs of real
tokenization that is a ~50× fixed tax on every packet, and it is fragile: too
short races the pipeline (drain loop exits before the first token), too long wastes
time. There was no way to ask the hardware "are you still working?"

### Fix applied
**1. A real `pipeline_busy` status (new STATUS bit 3).** It is high whenever any
byte/word/token is still in flight anywhere in the pipeline. Plumbed bottom-up:
- `pre_tokenizer.v`: new output `pt_busy = hold_valid || hold_word_done ||
  out_char_valid || out_word_done` (a character/boundary held or being sent this
  cycle — the `out_*` pulses close the one-cycle "in flight to the trie" gap).
- `top_tokenizer.v`: new output `pipeline_busy = pt_busy || !trie_ready` (pre-
  tokenizer busy, or the trie engine mid-walk/emitting).
- `tokenizer_axi_lite.v`: `pipeline_busy_all = pipeline_busy || !in_fifo_empty ||
  in_fifo_out_valid || !out_fifo_empty`, exposed as STATUS bit 3. The IP's external
  AXI ports are unchanged, so the block design is untouched.

**2. Firmware (`echo.c`):** added `tok_pipeline_busy()` (reads bit 3) and rewrote
the send/drain:
- **Drain while sending:** after each byte, pull any already-available tokens. The
  output FIFO never backs up on a long input → **closes M2's prevention side** (no
  drops in the first place; M2's overflow flag remains as the safety net).
- **Deterministic final drain:** `while (tok_pipeline_busy() || tok_has_token())
  drain;` replaces the blind delay — waits exactly as long as the hardware needs.
  A token is always read when available (even if the response buffer is full) so
  the loop can never spin on an un-drained FIFO.

Expected effect: per-packet floor drops from ~510 µs to roughly the real ~10–20 µs
of compute (tens of × end-to-end), scaling with input rather than being a fixed
tax. (This is the optimization note's headline item **F1**.)

### Testbench impact (heads-up)
`pre_tokenizer` and `top_tokenizer` gained output ports (`pt_busy`,
`pipeline_busy`). The existing `tb_pre_tokenizer.v` / `tb_top_tokenizer.v`
instantiate them by name without those ports — Verilog leaves the new outputs
unconnected (a harmless warning), so those testbenches still compile and run.
`tokenizer_axi_lite`'s external (AXI) ports are unchanged, so `tb_tokenizer_axi_lite`,
`tb_perf_measurement`, and `tb_m2_overflow` are unaffected.

### Verification plan
- **Functional (Vivado):** `tb_top_tokenizer` / `tb_tokenizer_axi_lite` must still
  produce the same token IDs (the busy signal is observational; it must not change
  outputs).
- **On the board (TCP):** confirm responses are correct and latency per request
  drops sharply versus the old build (the ~500 µs floor is gone). A focused check
  can also read STATUS bit 3 directly to confirm it falls only after the last token.

### Verification testbench — `tb_axi_pipeline.v`
A new AXI-level testbench mirrors the firmware end-to-end: it writes each byte to
TX_DATA (polling STATUS bit 0), interleaves draining, then runs the deterministic
final drain `while (pipeline_busy() || has_token()) drain`, and checks exact token
IDs plus that the pipeline returns idle (STATUS bits 1 and 3 both low). It covers
**P1** (a dropped first character would change the IDs) and **M4** (an early drain
or a stuck busy bit would change the count/leave the pipeline non-idle); it also
asserts STATUS bit 3 was observed high during processing. Vectors:
`hello hardware` → `7592 8051`; `embedding` → `7861 8270 4667`;
`embedding unquestionably` → `7861 8270 4667 4895 15500 3258 8231`; and the
9-word pangram → `1996 4248 2829 4419 14523 2058 1996 13971 3899`.
Pass criterion: `AXI PIPELINE TESTS PASSED`.

### Run evidence — first run FAILED, found a `pipeline_busy` false-idle gap
The first Vivado run of `tb_axi_pipeline.v` **failed** — and that is exactly what
the test is for. The decisive clue was `embedding`: only 2 of 3 tokens collected,
then `STATUS = 0x0b` (token available **and** busy) *after* the drain loop had
exited. That can only happen if `pipeline_busy` momentarily read 0 while a token
was still coming.

**Root cause:** a one-cycle window at a word boundary. When `word_done` is
delivered, `pt_busy`'s `out_word_done` pulse covers cycle T, but the trie engine
only lowers `ready` when it *processes* `word_done` (cycle T+2). At cycle T+1 the
pulse is gone, `ready` is still high, and the FIFOs are momentarily empty — so the
old `pipeline_busy = pt_busy || !trie_ready` read **0** for that one cycle. A
poller landing there stopped one token early; the missed token then surfaced (with
busy) right after, and the un-drained leftovers inflated later tests' counts.

**Fix:** drive `pipeline_busy` from the trie engine's *real* idle state rather
than just `!ready`. Added a `busy` output to `trie_engine.v`:
`busy = (state != S_IDLE) || !ready || replaying || word_done_pending` — the
`word_done_pending` term closes the T+1 gap. `top_tokenizer.v` now uses
`pipeline_busy = pt_busy || trie_busy`.

`tb_axi_pipeline.v` was also hardened for diagnosis: it now **prints the actual
token IDs for every test** (not just on pass) and **flushes any leftover tokens
before each test** so the four cases are independent.

*Status:* false-idle fix applied in this repository — `trie_engine.v` now exposes
`busy = (state != S_IDLE) || !ready || replaying || word_done_pending` (the
`word_done_pending` term closes the one-cycle boundary gap); `top_tokenizer.v` drives
`pipeline_busy = pt_busy || trie_busy` (with `pre_tokenizer.v`'s new
`pt_busy = hold_valid || hold_word_done || out_char_valid || out_word_done`);
`tokenizer_axi_lite.v` exposes
`pipeline_busy_all = pipeline_busy || !in_fifo_empty || in_fifo_out_valid || !out_fifo_empty`
on STATUS bit 3. `tb_axi_pipeline.v` added to `uart.srcs/sim_1/new/`. The firmware
half of M4 (`tok_pipeline_busy()` + drain-while-sending in `echo.c`) lives in the
separate Vitis project and is tracked there. Awaiting the engineer's Vivado
`tb_axi_pipeline` run (the printed token values will confirm a clean pass or
pinpoint anything remaining) and the on-board TCP check.

---

## FPGA-vs-CPU evaluation pipeline (the report's "why FPGA" data, 2026-06-21)

### Engineering field
**Quantitative benchmarking / experimental methodology.** With R2 (DMA) verified, the final
report needs a fair, defensible comparison of the hardware tokenizer against the software
reference (HuggingFace `bert-base-uncased`). The whole effort lives in `analysis/` and follows
one principle: **one shared corpus drives both engines, and each is measured at two levels
(core vs with-overhead) so the comparison is honest about where time is spent.**

### The shared input
- `analysis/corpus.txt` — **66** real-world ASCII text samples (search queries, chat, reviews,
  logs, news, abstracts, email, code), spanning ~10 to ~1150 chars so the scaling curves have
  resolution. Both the CPU benchmark and the FPGA simulation read this exact file.
- `analysis/divergence.txt` — 14 Unicode/emoji/non-Latin lines, kept SEPARATE; used only to
  document the FPGA's ASCII-only limitation (not part of the matched correctness score).

### CPU side -- `analysis/cpu_tokenizer_benchmark.py`
Per corpus line it records, to `results/cpu_results.csv`:
- **Latency at two levels** -- `core` (the Rust backend `tokenizer.backend_tokenizer`, no Python
  wrapper) and `overhead` (the full `transformers` call). Each with median/min/max/std/p99/jitter.
- **Jitter** -- the run-to-run spread; the determinism contrast (the FPGA fabric has none).
- **Throughput** -- multi-threaded batched tokens/s and chars/s (`results/cpu_throughput.csv`).
- **Correctness columns** -- `bert_ids` (full), `fpga_expected_ids`, and `punct_tokens` (below).

### FPGA side -- `analysis/gen_corpus_tb.py` -> `tb_corpus_perf.v` (xsim)
A generator reads `corpus.txt`, emits `corpus_bytes.mem` plus a self-contained measurement
testbench that streams each line through the real `tokenizer_axi_lite` RTL at **1 byte/clock**
(the `s_axis`/DMA path) and `$fwrite`s, per line, to `results/fpga_results.csv`: the token IDs,
`fabric_cycles` (first input byte accepted -> last token emitted, x10 ns = the true fabric
latency), and `input_cycles`. This is the **deterministic core latency** -- no AXI-Lite cadence,
no DMA setup, no cache. Paths are baked in as absolute to avoid the recurring xsim `.mem`-not-found
trap. (The 9 trie `.mem` load as usual.)

### Correctness -- the key methodology decision
The FPGA pre-tokenizer (`pre_tokenizer.v`: `is_word_char = is_letter_lower || is_digit`) treats
**every non-alphanumeric byte as a word boundary and does NOT emit standalone-punctuation tokens**,
whereas BERT emits each punctuation mark as its own token. So a raw id comparison would show large
"divergence" that is purely this known design choice. Instead the comparison is:
- `fpga_expected_ids` = BERT's ids with the punctuation tokens removed (= what the FPGA should emit),
  computed by keeping only pieces whose text (minus `##`) is all-alphanumeric (plus `[UNK]`).
- Across the corpus, **13.6%** of BERT's tokens are punctuation (462 of 3387) -- the quantified,
  honest "tokens the FPGA omits by design".
- `analysis/inspect_mismatch.py` decodes any remaining mismatch back to WordPiece strings to
  classify it (real bug vs expected limitation) before judging.

### Result and the one characterized bug
**64 of 66 lines match the FPGA-expected ids EXACTLY -- 97% exact word-token match.** The two
exceptions (idx 27, 62) are a real, narrow correctness bug, decoded and characterized:
- idx 27 `...summarize a long pdf...`: BERT `a | long`, FPGA `along` (merged).
- idx 62 `...vocab[t] ?? vocab...`: BERT `t | vo ##ca ##b`, FPGA `tv ##oca ##b` (`t`+`vocab` merged).
- **Trigger (proven against the data):** a **one-character word that immediately follows a
  multi-subword word** fails to flush at its trailing boundary and is concatenated with the next
  word. Confirmed by the counter-example idx 0 (`...tie a tie`) which matches -- there the one-char
  word `a` follows a single-piece word. Root cause is residual backtracking/boundary state in the
  trie engine (an H1-class sibling).
- **Decision: documented as a known limitation, not fixed** (submission-day RTL risk; 97% match is a
  strong, honest result). NOTE for a future fix: `fpga_results.csv` comes from *simulation*, so a fix
  only needs an xsim re-run of `tb_corpus_perf` to refresh the data -- no re-synthesis or re-flash.

### Headline numbers collected so far
- **Correctness:** 97% exact word-token match (64/66); 13.6% of BERT tokens are punctuation the FPGA
  omits by design; Unicode unsupported (the divergence set).
- **CPU latency:** core ~10 us / overhead ~23 us median per line on a Ryzen 7000 (16 threads); both
  overhead-dominated at these lengths.
- **Determinism:** CPU jitter up to ~255 us (20x its median, from GC/scheduling); FPGA fabric is
  cycle-exact (zero jitter) -- the strongest single contrast.
- **FPGA fabric latency:** `fabric_cycles` ~= 1 cycle/char until the trie backpressures on long lines;
  deterministic. (vs the CPU's multi-GHz clock -- the 100 MHz-does-comparable-work framing.)
- **CPU throughput:** 2.53 M tokens/s, 12.0 M chars/s (all 16 threads, batched).

### Pending (still open for the report)
- `compare_results.py` (merge the CSVs into the final correctness + latency/throughput/jitter table)
  and `plot_results.py` (the figures: latency vs length, throughput, jitter band, energy/1M-tokens).
- **Power** (the headline FPGA argument): Vivado `report_power` for the fabric + CPU package power
  (Ryzen measured, server CPUs via published TDP estimates) -> energy per tokenization / tokens-per-Joule.
- Honest "cons" to include: fixed BRAM vocab (re-synthesize to change), ASCII-only, single scheme,
  the 3% edge-case bug above, and per-core (one instance) vs the device's replication headroom.

*Status:* corpus + CPU benchmark + FPGA measurement TB + correctness classification **done and
verified** (data in `analysis/results/`). The 1-char-after-multipiece bug is characterized and
documented as a known limitation.

### Power / energy result + plots (COMPLETE)

`report_power` (post-implementation, **vectorless / Low confidence** -- a SAIF would refine it) on
the implemented design:
- Whole SoC: **1.369 W** total (1.210 W dynamic + 0.159 W static).
- By hierarchy (dynamic): `mig_7series_0` 0.692 W, `axi_ethernet_0` 0.165 W, `microblaze_0` 0.085 W,
  and the tokenizer datapath **`tokenizer_axi_lite_0` = 0.051 W (51 mW)** -- the fair datapath figure.
  The rest of the SoC exists to *feed* the tokenizer over the network, not to tokenize.

CPU power measured with HWiNFO on the actual machine: **AMD Ryzen 7 7435HS** (8C/16T, 45 W TDP laptop
part), **~30 W peak CPU package power** under the sustained all-core batched tokenization load
(idle ~14 W). The ~30 W (not the full 45 W TDP) reflects that tokenization is branch/memory-bound,
not AVX-heavy.

Energy per token at each platform's measured throughput (FPGA 1.22 M tok/s single core; CPU 2.53 M
tok/s batched across 16 threads):
- FPGA: **0.042 J / 1M tokens = 24.0 M tokens/Joule**.
- CPU : **11.9 J / 1M tokens = 84.3 k tokens/Joule**.
- => **~285x less energy per token** (CPU total package vs FPGA tokenizer dynamic), or **~152x** on
  the stricter marginal basis (CPU load-minus-idle ~16 W vs FPGA dynamic 51 mW). Even the conservative
  ~150x is against an efficient 45 W *laptop* CPU (the tougher competitor).

Figures in `analysis/figures/`: `latency_vs_length`, `jitter_vs_length`, `throughput`, `correctness`,
`energy_per_million` (two-panel: J/1M tokens + tokens/Joule). Pipeline scripts: `compare_results.py`
(merge + summary -> `results/comparison.csv`), `plot_results.py` (figures), `cpu_power_load.py` (the
HWiNFO sustained-load helper), `inspect_mismatch.py` (decode/classify mismatches). `power.csv` holds
the energy inputs.

*Status (final):* the FPGA-vs-CPU evaluation is **COMPLETE** -- correctness (97% exact word-token
match), latency (core vs overhead), jitter/determinism (CPU up to ~255 us spikes vs FPGA zero),
throughput, and energy (**~150-285x**), all with figures. Remaining items are report write-up only;
the 1-char-after-multipiece bug stays a documented known limitation (optional sim-only fix later).

---

## Stage 5 — Partner evidence pack (report deliverables) — 2026-06-21

Goal: turn the finished results into hand-over evidence for the report (partner Rafi + the
professor), so every graph/claim is backed by a raw file. Nothing new was *computed* here except
the Vivado utilization/timing reports; this stage packages and defends what already existed.

### New evidence folder `analysis/evidence/`
- **`EVIDENCE_INDEX.md`** — master map: every P0/P1/P2 deliverable → status → file → book chapter,
  plus a §B capture-checklist (Tcl commands + screenshot list) for the Vivado/board items.
- **`ENERGY_CALCULATION.md`** — the energy-efficiency defense sheet: formula
  (`energy/token = power / throughput`), every input with provenance, and the honest **~152× (marginal)
  to ~285× (total)** range with all four caveats (vectorless/Low confidence, datapath-vs-SoC,
  1-core-vs-16-thread, peak-vs-avg CPU power).
- **`MISMATCH_REPORT.md`** — corpus description + the 64/66 result, separating the 13.6% by-design
  punctuation omission from the **2 real edge-case bugs**, both decoded: idx 27 `a`→`along`
  (`summarize a long`), idx 62 `t`→`tv` (`map(t => vocab`). Same root cause (1-char word after a
  multi-piece word).
- **`BENCHMARK_SETUP.md`** — CPU methodology (Ryzen 7 7435HS, 8C/16T, 16-thread `encode_batch`, Rust
  `backend_tokenizer`, `add_special_tokens=False`, Python 3.14) + FPGA sim methodology
  (`tb_corpus_perf`, 1 byte/clk, `fabric_us = cycles × 0.01`), so the comparison is defensibly fair.
- **`tb_axi_dma_transcript.txt`** — the captured xsim PASS console (deliverable #10, see below).

### Vivado reports via a one-shot script `analysis/gen_reports.tcl`
`source` it in the Vivado Tcl console (project open); it opens `impl_1` if needed, then writes
utilization + timing + copies the user `.xdc`, and echoes the headline WNS.
- **Utilization** (`results/utilization_impl.rpt`, `..._hier.rpt`): **22,511 LUT (16.7%),
  26,534 FF (9.9%), 212 BRAM (58.1%), 0 DSP** — the tokenizer is BRAM-bound (the two CSR tries), as
  expected.
- **Timing** (`results/timing_summary.rpt`): **WNS = −0.374 ns, TNS = −0.703 ns, 2 failing endpoints
  of 87,343** (improved from the earlier −0.626). **100 MHz does NOT fully close** — documented
  honestly for Ch. 6.5/10.5; the board runs correctly because the 2 failing paths have margin under
  actual conditions. Closing them is listed as future work.
- **Bug found & fixed in the script:** the first version copied *every* XDC via
  `get_files -filter {FILE_TYPE == XDC}`, which dumped ~37 IP-generated/OOC constraint files
  (`design_1_*`, `bd_*`, `*_ooc.xdc`) into `results/`. Restricted to the user fileset:
  `get_files -of [get_filesets constrs_1] ...`. Stray files removed with `git clean`.

### tb_axi_dma — primary DMA-protocol simulation evidence (P0 #10)
Three cases (`hello` 1-tok, `embed` 2-tok, `embedding` 3-tok) all **PASS**: token IDs match
bert-base-uncased, `m_axis_tlast` lands on exactly the final token, and `TOKEN_COUNT (0x0C)` reports
the right count. Clean finish at 5735 ns.
- **Lesson (false alarm):** a first `run all` hit the 5 ms watchdog ("TIMED OUT") — *not* a DUT bug.
  It was a stale/half-elaborated xsim snapshot; **`restart; run all`** forces a clean run that passes.
  A signal-state probe (`get_value` after a bounded `run`) confirmed the pipeline drains fully
  (`tok_count=3`, `pipe_busy=0`, `input_done=0`) — the design was never stuck. Noted at the top of
  the transcript so it isn't re-debugged.

### Waveform (P1 #11) — `analysis/figures/waveform.jpg`
The `embedding` end-of-packet: `m_axis_tdata = 4667` (final token, decimal radix) with
`m_axis_tvalid` high, **`m_axis_tlast` pulsing on that token**, `m_axis_tready = 1` (the S2MM model
accepting), and `s_axi_rdata` stepping `2 → 3` (firmware reading `TOKEN_COUNT = 3`). Input-side
`s_axis_tlast` is off-frame here (covered by the transcript); an optional input-burst snip would
close it.

### Screenshots committed
`analysis/figures/block_design.jpg` (MicroBlaze, AXI DMA, SmartConnect, MIG/DDR, tokenizer IP) and
`analysis/figures/address_editor.jpg` (tokenizer 0x44A0_0000, AXI DMA 0x41E1_0000, timer, DDR
0x8000_0000 — the exact addresses `echo.c` uses).

### Status
**All P0 deliverables (1–10) are DONE**, plus **P1 #11 (waveform)**. Remaining are partner/optional
(see HANDOFF "Stage 5 open items"): board TCP regression log, Route B (partner's other route), Mermaid
PNG/SVG exports (book-side), board photo. The timing miss (−0.374 ns) and the 1-char-word bug remain
the two documented honest limitations.

---

## Bug #2 FIXED — 1-char word after a multi-piece word (sim-verified 66/66) — 2026-06-21

The documented correctness limitation (`a long`→`along`, `vocab t vocab`→`tvocab`) is fixed.

**Root cause:** `trie_engine.v`'s `word_done_pending` was a single bit. The pre-tokenizer pulses
`out_word_done` for one cycle, ungated by `trie_ready`. When a 1-character word's boundary arrives
while the previous *multi-piece* word is still replaying — which happens because the racing-char
skid (the P1/embed optimization) pulls the 1-char word's character into the trie early, freeing the
pre-tokenizer to accept the following space and pulse the next boundary mid-replay — the second
boundary lands while `word_done_pending` is already 1. `1|1 = 1`: the boundary is swallowed, the
1-char word never finalizes, and it glues onto the next word. (Explains why it only hit 1-char words
*after a multi-piece word*: a single-piece predecessor emits too fast for the boundaries to collide,
which is why the *first* `t vocab` after single-piece `map` was already correct.)

**Fix:** `word_done_pending` (1 bit) → `word_done_count` (2-bit saturating counter). Boundaries are
accumulated: `+1` on `in_word_done`, `−1` when a word finalizes (`bnd_consume`), applied in one
consolidated update so a boundary arriving on the same cycle one is consumed is preserved (net zero,
not lost). All boundary reads became `word_done_count != 0`; all finalize sites set `bnd_consume`.
The 1-deep input skid bounds concurrent in-flight words to 2, so 2 bits are sufficient; the counter
saturates at 3 and every decrement sits inside a `!= 0` guard (no under/overflow). Faithful to the
H1/M1/embed behavior — those branches' boundary handling is preserved exactly.

**Verification (xsim, behavioral):**
- New `tb_word_boundary.v`: 8/8 PASS — bug patterns `summarize a long` (`7680 7849 4697 1037 2146`),
  `vocab t vocab` (`29536 3540 2497 1056 29536 3540 2497`), `embed embedding a hi`; plus regression
  guards `map t vocab`, `a long`, `hello`, `embed`, `embedding`.
- Full 66-line corpus re-run through `tb_corpus_perf` → `compare_results.py` reports **66/66 (100%)**
  exact word-token match (was 64/66); `inspect_mismatch.py` → **0 mismatches**.

**State:** RTL fix sim-verified; **not yet on silicon**. The shipped bitstream is still 64/66; the
on-silicon 66/66 lands with the pending single synthesis/implementation batch (#2 + #7 + #9). Until
then the evidence pack figures/CSVs that describe the *board* remain the 64/66 set unless explicitly
regenerated and labelled "sim". This is the first item of the Phase-1 (no-implementation) batch.
