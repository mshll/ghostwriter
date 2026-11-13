# Evaluation

Changes to suggestion quality or speed need numbers. `gw-eval` runs the app's prompt builder and engine on a set of rows. It needs no permissions and types into no app.

```sh
# Download the default model
swift run --package-path Packages/GhostwriterKit -c release gw-eval --download gemma-4-e2b

# Run it on the held-out set (--model <file.gguf> picks another model)
swift run --package-path Packages/GhostwriterKit -c release gw-eval --set eval/heldout.jsonl
```

Always use `-c release`: debug builds are several times slower.

## Modes

| Flag | Measures |
|---|---|
| (none) | One suggestion per row: exact next word, accepted words, latency |
| `--score` | Bits per character of the real continuation. Compares models directly; lower is better. |
| `--typing` | Types each row and accepts matching suggestions: keystrokes saved. Add `--typing-speed 6 --engine continuous` to run on a clock, as in the app. |
| `--typos <set>` | Typo correction on word rows, for the spell checker alone and with the model judge at several margins. Reports precision, recall, false flags and latency. |
| `--proofread <set>` | Fix Grammar with Apple's on-device model on sentence rows: exact matches, injected typos fixed, other words changed, latency. |
| `--decode-curve` | GPU time of one decode by its number of tokens (1 to 16), after the prompts of the first rows of the set. Shows where a beam step plus a mid-line rerank gets expensive. |
| `--first-request` | The first request after each model load against the same request repeated with an empty cache, over the first rows of the set. `--warm-up` runs the engine's warm-up after each load. |

`--typing --engine continuous` prints the median and 95th percentile time of an engine unit (`unit50`, `unit95`); the default mode prints the time of the mid-line rerank. `--midline-candidates`, `--midline-tokens` and `--midline-beams` change how the mid-line rerank works; `gw-eval --help` lists them.

`gw-eval --help` lists every option. `--json out.json` saves each row's result.

## Sets

`eval/heldout.jsonl` has 150 hand-written rows. Each row is a JSON object with `before` and `after` (the text around the caret), `truth` (what the writer typed next), and optional `app`, `kind`, `lang` and `screen` (window text).

Larger sets contain text from the web, so they are not in git. Build them into `eval/data/` (ignored by git):

- `eval/scripts/build_web_set.py`: 700 rows of recent writing in 7 languages
- `eval/scripts/build_context_set.py`: replies with the thread the writer saw as window text
- `eval/scripts/build_typo_set.py`: `typos.jsonl`, typos injected into the two sets above (needs `web.jsonl`). Word rows (`kind: "typo"` or `"clean"`) are for `--typos`; sentence rows (`kind: "sentence"`) are for `--proofread`.
- `eval/scripts/build_common_typos.py`: `typos-common.jsonl`, well-known English misspellings (recieve, seperate) for `--typos`. Models have seen these often, so they are harder to catch than random slips.

`eval/scripts/compare_models.py` runs several models on several sets and prints one table.

## Your own writing

The sets above are public text, and by default `gw-eval` builds prompts without the examples of your writing and the word preferences the app adds. To measure those on what you write, build a set from a copy of your own database:

```sh
sqlite3 "file:$HOME/Library/Application Support/com.mshl.ghostwriter/ghostwriter.sqlite?mode=ro" \
    ".backup '$TMPDIR/ghostwriter-copy.sqlite'"
uv run --script eval/scripts/build_history_set.py "$TMPDIR/ghostwriter-copy.sqlite" --kind <bundle id>=aiPrompt
```

The script splits your recorded writing by date. The older sessions become `history.jsonl`, the newer ones `test.jsonl`, with rows cut at word boundaries. It drops test sessions that repeat a history session. The database does not store field kinds, so `--kind` sets them per app. Both files hold your writing. They go to `eval/private/history/`, which git ignores. Keep them on your Mac.

```sh
gw-eval --score --set eval/private/history/test.jsonl --history eval/private/history/history.jsonl
```

With `--history`, each request gets examples and word bias as in the app at the default personalization strength.

| Flag | Default | Changes |
|---|---|---|
| `--examples N` | 2 | Examples of your writing in the prompt; 0 turns them off |
| `--bias-strength X` | 1.5 | Word preference bias in the beam search; 0 turns it off. `--score` ignores it. |
| `--same-app-boost X` | 1.5 | Ranking weight for examples from the same app |
| `--recency-boost X` | 0.2 | Ranking weight for recent examples |

`eval/scripts/compare_history.py` runs the set with each setting off and on, and prints the differences with 95% confidence intervals.

Your sessions include suggestions you accepted, so the set favors the model a little. The script prints how many accepted characters there are, as an upper bound.

## In a pull request

Give the command, the set, the numbers before and after, and your Mac's chip and memory for any latency number.
