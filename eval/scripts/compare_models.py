# /// script
# requires-python = ">=3.11"
# ///
"""Runs gw-eval --score and --typing for each model on each set and prints one comparison table.

usage: uv run --script eval/scripts/compare_models.py --out DIR --sets a.jsonl [b.jsonl] --models x.gguf [y.gguf]
       [--typing-sets a.jsonl] [--typing-speed 6] [--extra "--beams 4"] [--summary-only]

Results are cached as DIR/<model>/<set>.<mode>.json, typing runs with a speed as <set>.typing.<N>cps.json;
delete a file to rerun it.
"""

import argparse
import json
import shlex
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GW_EVAL = ROOT / "Packages/GhostwriterKit/.build/release/gw-eval"


def run(model: Path, dataset: Path, mode: str, name: str, out: Path, extra: list[str]) -> Path:
    target = out / model.stem / f"{dataset.stem}.{name}.json"
    if target.exists():
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    command = [str(GW_EVAL), f"--{mode}", "--set", str(dataset), "--model", str(model), "--json", str(target), *extra]
    print("$", shlex.join(command), file=sys.stderr, flush=True)
    log = target.with_suffix(".log")
    with log.open("w") as handle:
        status = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT).returncode
    if status != 0:
        print(f"failed ({status}), see {log}", file=sys.stderr)
    return target


def load(path: Path) -> list[dict]:
    return json.loads(path.read_text()) if path.exists() else []


def bpc(rows: list[dict]) -> float | None:
    characters = sum(row["characters"] for row in rows)
    return sum(row["bits"] for row in rows) / characters if characters else None


def saved(rows: list[dict]) -> float | None:
    characters = sum(row["characters"] for row in rows)
    return 1 - sum(row["keystrokes"] for row in rows) / characters if characters else None


def useful(rows: list[dict]) -> float | None:
    shown = sum(row["shown"] for row in rows)
    return sum(row["used"] for row in rows) / shown if shown else None


def late(rows: list[dict]) -> float | None:
    requests = sum(row["requests"] for row in rows)
    return sum(row["late"] for row in rows) / requests if requests else None


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def cell(value: float | None, scale: float = 1, digits: int = 3) -> str:
    return "-" if value is None else f"{value * scale:.{digits}f}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--sets", type=Path, nargs="+", required=True)
    parser.add_argument("--typing-sets", type=Path, nargs="*", default=None)
    parser.add_argument("--models", type=Path, nargs="+", required=True)
    parser.add_argument("--typing-speed", type=float)
    parser.add_argument("--extra", default="")
    parser.add_argument("--summary-only", action="store_true")
    args = parser.parse_args()
    typing_sets = args.sets if args.typing_sets is None else args.typing_sets
    extra = shlex.split(args.extra)
    speed = args.typing_speed
    typing_name = "typing" if speed is None else f"typing.{speed:g}cps"
    typing_extra = extra if speed is None else [*extra, "--typing-speed", f"{speed:g}"]

    if not args.summary_only:
        for model in args.models:
            for dataset in args.sets:
                run(model, dataset, "score", "score", args.out, extra)
            for dataset in typing_sets:
                run(model, dataset, "typing", typing_name, args.out, typing_extra)

    for dataset in args.sets:
        scores = {model: load(args.out / model.stem / f"{dataset.stem}.score.json") for model in args.models}
        languages = sorted({row["lang"] for rows in scores.values() for row in rows},
                           key=lambda lang: -sum(row["lang"] == lang for row in next(iter(scores.values()))))
        print(f"\n## {dataset.name}: bits per character of the truth (lower is better)\n")
        print("| model | all | " + " | ".join(languages) + " |")
        print("|---|---|" + "---|" * len(languages))
        for model, rows in scores.items():
            by_lang = defaultdict(list)
            for row in rows:
                by_lang[row["lang"]].append(row)
            print(f"| {model.stem} | {cell(bpc(rows))} | " + " | ".join(cell(bpc(by_lang[lang])) for lang in languages) + " |")

    for dataset in typing_sets:
        typing = {model: load(args.out / model.stem / f"{dataset.stem}.{typing_name}.json") for model in args.models}
        languages = sorted({row["lang"] for rows in typing.values() for row in rows},
                           key=lambda lang: -sum(row["lang"] == lang for row in next(iter(typing.values()))))
        at = "" if speed is None else f" at {speed:g} characters per second"
        late_header, late_rule = ("", "") if speed is None else (" late |", "---|")
        print(f"\n## {dataset.name}{at}: keystrokes saved % (higher is better), useful suggestions %, latency ms\n")
        print(f"| model | saved | useful | p50 | p95 |{late_header} " + " | ".join(languages) + " |")
        print(f"|---|---|---|---|---|{late_rule}" + "---|" * len(languages))
        for model, rows in typing.items():
            by_lang = defaultdict(list)
            for row in rows:
                by_lang[row["lang"]].append(row)
            latencies = [value for row in rows for value in row["milliseconds"]]
            print(f"| {model.stem} | {cell(saved(rows), 100, 1)} | {cell(useful(rows), 100, 1)} | "
                  f"{cell(percentile(latencies, 0.5), 1, 0)} | {cell(percentile(latencies, 0.95), 1, 0)} | "
                  + ("" if speed is None else f"{cell(late(rows), 100, 1)} | ")
                  + " | ".join(cell(saved(by_lang[lang]), 100, 1) for lang in languages) + " |")


if __name__ == "__main__":
    main()
