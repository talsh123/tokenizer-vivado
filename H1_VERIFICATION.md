# How to Verify Bug H1 Is Real

**Bug H1 (short):** When a word's final WordPiece is produced by a *backtrack
replay* while the end-of-word boundary is already latched, the trie-engine FSM
takes a path that was missing a next-state assignment. The result is one of:
- **Variant A:** a spurious **`[UNK]` = token `100`** appended to the word, or
- **Variant B:** the word's **final piece is dropped** (missing token).

This document gives you several independent ways to confirm the bug on the
**unfixed** RTL, and a list of candidate words likely to trigger it.

---

## 0. The one fact that makes checking easy

For input made only of ASCII **letters and digits**, a *correct* WordPiece
tokenizer **never emits `[UNK]` (token 100).**

Why: every single letter `a`–`z` and digit `0`–`9` is its own token in the
`bert-base-uncased` vocabulary, so the greedy longest-match can always fall back
to single characters. The pre-tokenizer only ever forwards letters/digits to the
trie (everything else is treated as a word boundary). So the trie can always
match *something*.

**Consequence — the simplest possible detector:**
> Send normal lowercase English words. **Count the `100`s in the output.
> There must be zero. Any `100` is a bug (H1 Variant A, or H2).**

That check needs **no reference tokenizer at all.** Variant B (a *dropped*
token) does need a reference to notice the missing piece — covered in §3.

---

## 1. When exactly does H1 fire? (so the word list makes sense)

The engine tokenizes a word greedily:
1. Walk the **root** trie, remember the longest token that matched (`em`).
2. Emit it, then **replay** the leftover buffered characters through the
   **continuation** (`##`) trie to get the next piece (`##bed`), and repeat
   (`##ding`).

Meanwhile the end-of-word space is latched into a sticky flag
(`word_done_pending`) **very soon** after the last letter enters the engine — so
during the final backtrack(s), the boundary is almost always already pending.

H1 fires when the **final piece is produced by a replay that completes while the
boundary is pending** (the `S_IDLE` replay-completion path). The premature clear
of `word_done_pending` on that path makes `S_EMIT` skip its finalization.

**Heuristic for "most likely to trigger":**
- **Multi-piece words (2–4 WordPieces).** Single-token words (`hello`,
  `hardware`) cannot trigger it.
- Words whose **leading characters run deep into the root trie before
  backtracking** (i.e. the first letters spell a long, common word/prefix). The
  deeper the root walk, the more characters are buffered before the first emit,
  which forces the tail to be **replayed** (the buggy path) rather than streamed.

---

## 2. Symptoms — what a triggered bug looks like

Send `embedding` (correct answer = 3 tokens `7861 8270 4667`):

| Output you see | Meaning |
|---|---|
| `7861 8270 4667` | Correct — bug did **not** fire on this word |
| `7861 8270 4667 100` | **H1 Variant A** — spurious `[UNK]` appended |
| `7861 8270` | **H1 Variant B** — final piece `##ding` dropped |
| `7861 8270 4667 4667` / other extra | other FSM mis-step — report it |

General rule: **wrong token count** and/or **any `100`** on clean English text.

---

## 3. Three ways to run the check

### Method A — Vivado simulation (most controlled)
1. Open `tokenizer-vivado/uart.xpr`.
2. Set **`tb_top_tokenizer`** as simulation top, **Run Behavioral Simulation**,
   `run -all`.
3. The existing testbench already includes `embedding` (expects 3 tokens) and
   `unquestionably` (expects 4). **If either reports `FAIL: Expected N tokens,
   got N+1` (or `N-1`), the bug is reproduced.** Read the console `Token[i]`
   lines — a `got 100` is Variant A.
4. To test more words, copy a `send_string(...)` / `verify_tokens(...)` block and
   add words from §4. The testbench is self-checking, so any count/value
   mismatch prints `*** TEST FAILED ***`.

> This is the cleanest evidence for the report because the testbench prints
> expected-vs-actual automatically.

### Method B — On the real board over TCP (no testbench)
The firmware runs a tokenizer server on **port 7** and returns space-separated
decimal token IDs. Program the board, then from a PC on the same subnet:

```python
# tok_client.py  — send each word, print returned token IDs
import socket
BOARD_IP = "192.168.1.10"     # <-- set to your board's IP

WORDS = open("words.txt").read().split()   # one word per line/space

def tokenize(word):
    s = socket.socket(); s.settimeout(3); s.connect((BOARD_IP, 7))
    s.sendall(word.encode())               # firmware appends the boundary space
    data = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk: break
            data += chunk
            if b"\n" in chunk: break
    except socket.timeout:
        pass
    s.close()
    return [int(x) for x in data.split() if x.strip().isdigit()]

for w in WORDS:
    ids = tokenize(w)
    flag = "  <-- has 100 (UNK)!" if 100 in ids else ""
    print(f"{w:<28} {ids}{flag}")
```

Then scan the output: **any line tagged `has 100` is a confirmed H1/H2 hit.**

### Method C — Build ground truth with HuggingFace (for Variant B / counts)
To catch *dropped* tokens you need the correct answer to compare against:

```python
# reference.py — expected tokenization from the same vocab
from transformers import BertTokenizer
tok = BertTokenizer.from_pretrained("bert-base-uncased")
for w in open("words.txt").read().split():
    ids = tok.encode(w, add_special_tokens=False)   # no [CLS]/[SEP]
    print(f"{w:<28} {ids}")
```

Compare this list element-by-element with the hardware output from Method B.
A diff that is **+1 token ending in `100`** = Variant A; **−1 token** = Variant B.

> Use the *same* `vocab.txt` that generated the `.mem` files so the IDs line up.

---

## 4. Candidate trigger words

All are multi-piece in `bert-base-uncased`. The **expected pieces** column is the
WordPiece split (confirm IDs with Method C — the decision criterion is *count*
and *absence of `100`*, not the exact IDs). Words are grouped by how deep the
leading root walk is (deeper ⇒ more likely to force the buggy replay path).

### Group 1 — known-good reference vectors (already in the testbenches)
| Word | Expected pieces | Expected IDs |
|---|---|---|
| `embedding` | `em ##bed ##ding` | `7861 8270 4667` |
| `unquestionably` | `un ##quest ##ion ##ably` | `4895 15500 3258 8231` |

### Group 2 — deep leading word/prefix (highest-priority candidates)
| Word | Expected pieces (confirm with HF) |
|---|---|
| `internationalization` | `international ##ization` |
| `characterization` | `character ##ization` |
| `transformation` | `transform ##ation` |
| `understanding` | `under ##standing` |
| `representation` | `representation`→`represent ##ation` |
| `configuration` | `con ##figuration` / `config ##uration` |
| `implementation` | `imp ##lement ##ation` |
| `snowboarding` | `snow ##board ##ing` |
| `multiprocessing` | `multi ##processing` |
| `tokenization` | `token ##ization` |

### Group 3 — common 2–3 piece words
| Word | Expected pieces (confirm with HF) |
|---|---|
| `tokenizer` | `token ##izer` |
| `preprocessing` | `pre ##processing` |
| `biotechnology` | `bio ##technology` |
| `semiconductor` | `semi ##con ##ductor` |
| `microcontroller` | `micro ##con ##troller` |
| `cryptocurrency` | `crypto ##currency` |
| `nanotechnology` | `nano ##technology` |
| `unbelievable` | `un ##bel ##ievable` |
| `misunderstanding` | `mis ##under ##standing` |
| `backpropagation` | `back ##pro ##pa ##gation` |

### Group 4 — long words (>32 chars also stress buffer limit M1, see note)
| Word | Note |
|---|---|
| `antidisestablishmentarianism` | 28 chars — fits buffer, many pieces |
| `pneumonoultramicroscopicsilicovolcanoconiosis` | **45 chars > 32**: will *also* hit M1 buffer overflow; use only after M1 is understood, otherwise the result is corrupted for a different reason |

> For an H1-only test, **stay ≤ 32 characters** so you don't also trip M1.

A ready-to-paste `words.txt` (Groups 1–3, all ≤ 32 chars):

```
embedding
unquestionably
internationalization
characterization
transformation
understanding
configuration
implementation
snowboarding
multiprocessing
tokenization
tokenizer
preprocessing
biotechnology
semiconductor
microcontroller
cryptocurrency
nanotechnology
unbelievable
misunderstanding
```

---

## 5. Decision criteria (how to conclude)

Run the batch (Method A or B) on the **unfixed** RTL and apply:

- **Any `100` appears** on this alphanumeric input → **H1 Variant A confirmed**
  (a spurious `[UNK]`). No reference needed.
- **Token count is one short** vs HuggingFace (Method C) with no `100` →
  **H1 Variant B confirmed** (dropped final piece).
- **All counts match HuggingFace and no `100`** on every word → H1 did not
  trigger on this set. Try more Group-2 words, or capture a waveform of
  `state`, `replaying`, `word_done_pending`, `out_token_valid` for one
  multi-piece word and look for the FSM dwelling in `S_EMIT` for 2 cycles
  (the tell-tale of the missing next-state).

After you have the "before" evidence, re-run the identical batch on the **fixed**
`trie_engine.v`: every word should match HuggingFace exactly with zero `100`s.
That before/after pair is the proof for the report.

---

## 6. Notes / honesty about timing

H1 is **timing-dependent**: whether a given word takes the buggy replay-
completion path depends on the exact cycle interleaving of character delivery vs.
trie processing. That is *why* a batch of words is provided rather than a single
guaranteed word — running ~20 multi-piece words makes it very likely several land
on the buggy path. The waveform check in §5 is the fully deterministic fallback
if a batch somehow comes back clean.
