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

`gw-eval --help` lists every option. `--json out.json` saves each row's result.

## Sets

`eval/heldout.jsonl` has 150 hand-written rows. Each row is a JSON object with `before` and `after` (the text around the caret), `truth` (what the writer typed next), and optional `app`, `kind`, `lang` and `screen` (window text).

Larger sets contain text from the web, so they are not in git. Build them into `eval/data/` (ignored by git):

- `eval/scripts/build_web_set.py`: 700 rows of recent writing in 7 languages
- `eval/scripts/build_context_set.py`: replies with the thread the writer saw as window text
- `eval/scripts/build_typo_set.py`: `typos.jsonl`, typos injected into the two sets above (needs `web.jsonl`). Word rows (`kind: "typo"` or `"clean"`) are for `--typos`; sentence rows (`kind: "sentence"`) are for `--proofread`.
- `eval/scripts/build_common_typos.py`: `typos-common.jsonl`, well-known English misspellings (recieve, seperate) for `--typos`. Models have seen these often, so they are harder to catch than random slips.

`eval/scripts/compare_models.py` runs several models on several sets and prints one table.

## In a pull request

Give the command, the set, the numbers before and after, and your Mac's chip and memory for any latency number.
