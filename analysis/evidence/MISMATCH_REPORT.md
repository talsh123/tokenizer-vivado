# Correctness & mismatch report — 66/66 exact match (100%) after the #2 fix

> **UPDATE (#2 fixed, sim-verified):** the 2 edge-case mismatches below were **root-caused and
> fixed** in `trie_engine.v` (`word_done_pending` single bit → `word_done_count` saturating
> counter). The fixed RTL scores **66/66 (100%)** in xsim (`tb_word_boundary` 8/8 PASS; full-corpus
> `compare_results.py` → 100.0%, `inspect_mismatch.py` → 0 mismatches). This section is kept because
> it documents the bug. **Note on hardware state:** the result is **sim-verified**; the on-silicon
> 66/66 lands once the pending synthesis/implementation re-flash is done (the previously *shipped*
> bitstream is 64/66). See JOURNAL "Bug #2 fixed" and the root-cause write-up there.

**Purpose:** defend the correctness graph and pre-empt *"why only 97%?"* (Book Ch. 10.2)

**Corpus:** `analysis/corpus.txt` — 66 lines of real-world ASCII text (search queries, chat,
product reviews, log lines, news, paper abstracts, an email, a code snippet); 16,099
characters total. This single file is the shared input for **both** engines.

**Reference:** HuggingFace `bert-base-uncased`, `BertTokenizerFast.backend_tokenizer`
(the Rust core, no Python wrapper). Token IDs compared element-by-element per line.

---

## 1. Headline numbers (`results/comparison.csv`)

| Metric | Value |
|---|---|
| Corpus lines | 66 |
| Lines that match HuggingFace **exactly** | **64 (97.0%)** |
| Lines with an edge-case mismatch | 2 (idx 27, idx 62) |
| BERT tokens total | 3,387 |
| Word-tokens the FPGA reproduces | 2,925 |
| Punctuation tokens omitted **by design** | 462 (13.6%) |

Two distinct things are being measured, and the chapter must keep them separate:

- **Punctuation (13.6%)** is *not* an error. The hardware `pre_tokenizer` defines
  `is_word_char = is_letter_lower || is_digit`; everything else is a word boundary and is
  dropped. BERT emits standalone punctuation tokens; this tokenizer does not. This is a
  documented design choice, not a bug, and it is excluded from the 64/66 match count
  (which compares word-tokens only).
- **The 2 mismatches** below are genuine edge-case bugs in word reassembly.

---

## 2. The two mismatches (decoded to WordPiece strings)

Both failures are the **same root cause**: a **one-character word** immediately following a
word that was split into sub-pieces gets glued onto the *next* word instead of standing
alone. This is a residual of the cross-piece boundary handling (the "H1-class" bug).

### idx 27 — `corpus.txt` line 28
> *"What is the best way to summarize a long PDF into action items?"* (63 chars)

| | tokens |
|---|---|
| HuggingFace (expected) | … `sum` `##mar` `##ize` **`a`** **`long`** `pdf` `into` `action` `items` |
| FPGA (got) | … `sum` `##mar` `##ize` **`along`** `pdf` `into` `action` `items` |

The single-letter word **`a`** following the split word `summarize` is merged with the
next word `long` → **`along`**. One extra/wrong token; everything else identical.

### idx 62 — `corpus.txt` line 63
> a 369-char JavaScript BPE snippet ending `… map(t => vocab[t] || vocab['[UNK]'])`

| | tokens (tail only) |
|---|---|
| HuggingFace (expected) | … `map` **`t`** `vo` `##ca` `##b` **`t`** `vo` `##ca` `##b` `un` `##k` |
| FPGA (got) | … `map` **`t`** `vo` `##ca` `##b` **`tv`** `##oca` `##b` `un` `##k` |

The second single-letter **`t`** merges with the following `vocab` → **`tv` `##oca` `##b`**
instead of `t` + `vo` `##ca` `##b`. Same pattern: 1-char word + following word.

---

## 3. Status / decision — FIXED (sim-verified)

- **Root cause:** `trie_engine.v`'s `word_done_pending` was a **single bit**. When a 1-character
  word's boundary arrives while the previous multi-piece word is still *replaying* (the racing-char
  skid pulls the 1-char word's character in early, freeing the pre-tokenizer to pulse the next
  boundary), the second boundary collided with the first (`1|1 = 1`) and was lost — so the 1-char
  word never got its own boundary and glued onto the next word.
- **Fix:** replaced the single bit with a **2-bit saturating counter** (`word_done_count`):
  boundaries are accumulated (+1 on `in_word_done`, −1 on each word finalize), so colliding
  boundaries are preserved. The 1-deep input skid bounds concurrent words to 2, so 2 bits suffice.
- **Verification:** `tb_word_boundary` 8/8 PASS (incl. `summarize a long`, `vocab t vocab`,
  `embed embedding a hi`); full corpus 66/66 (100%); `inspect_mismatch.py` 0 mismatches.
- **Hardware state:** sim-verified; on-silicon 66/66 follows the pending re-implementation/re-flash.

## 4. Regenerate
```
py ./inspect_mismatch.py        # joins cpu_results.csv + fpga_results.csv, decodes mismatches
```
