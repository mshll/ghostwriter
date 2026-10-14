# Models

Which models Ghostwriter offers for autocomplete, and why.

## Requirements

- **A base model.** Base (pretrained) models continue text. Instruct and chat models answer or rewrite it, which autocomplete must not do.
- **Many languages,** including Arabic, Japanese and Chinese.
- **A standard transformer.** The engine trims and copies KV cache sequences at any position ([ENGINE.md](ENGINE.md)). Hybrid and recurrent architectures (Qwen3.5, Granite 4.0-H, LFM2, Falcon-H1) do not support that.
- **Small and fast** enough to answer within a key press on a Mac with 8 to 16 GB of memory.

## Catalog

| Model | File |
|---|---|
| Gemma 4 E2B (default) | i1-Q5_K_M |
| Gemma 4 E4B | i1-Q5_K_M |
| Gemma 3 4B | i1-Q4_K_M |
| Gemma 3 1B | i1-Q4_K_M |

The files are importance-matrix quantizations from [mradermacher](https://huggingface.co/mradermacher). Each is pinned to a repository revision and checked against its SHA-256 after download (`Inference/Catalog.swift`). The app recommends a model from the Mac's memory and chip. Download sizes and how to add your own base model are in the [README](../README.md#models).

## Why these

15 base models were compared on 700 rows of real writing in 7 languages, published after their training data ([EVALUATION.md](EVALUATION.md)):

- **Gemma 4 E4B** predicts the text best of all models tested, including Ministral 3 8B and Qwen3 8B. It saves 44% of keystrokes, but is 1.7 times slower than E2B on an M1 Pro.
- **Gemma 4 E2B** saves 43% of keystrokes with a median latency of 153 ms. It is the best balance of quality and speed, so it is the default.
- **Gemma 3 4B** is as accurate as E2B with a smaller download. **Gemma 3 1B** is the only good fit for 8 GB of memory.

**Quantization.** The small gate tensors of Gemma 4 E-models break at 4 bits: a standard Q4_K_M of E4B loses much of its quality. Importance-matrix quantizations avoid this, which is why the catalog uses them.

**Apple Foundation Models** saved 18% of keystrokes against 41% for Gemma 4 E2B. Its API gives no plain continuation mode, so it tends to answer the text instead of continuing it. Ghostwriter uses it only for actions on selected text and the proofread shortcut, which are instructions by nature.
