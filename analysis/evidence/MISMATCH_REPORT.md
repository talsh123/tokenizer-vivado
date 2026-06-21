# Correctness & mismatch report — 64/66 exact match (97%)

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

## 3. Status / decision

- **Characterized, deferred.** The fix lives in the pre-tokenizer / boundary FSM
  (cross-piece word reassembly) and would need a sim re-run + re-synthesis. The team chose
  to **document, not fix**, for the report deadline.
- **Impact is bounded:** only triggers when a one-letter token (`a`, `t`, `i`, …) directly
  follows a multi-piece word with no punctuation between. 2 of 66 real-world lines (3%).
- Tracked in `CODE_REVIEW.md` §8 "Known limitations" and `HANDOFF.md`.

## 4. Regenerate
```
py ./inspect_mismatch.py        # joins cpu_results.csv + fpga_results.csv, decodes mismatches
```
