# /// script
# requires-python = ">=3.11"
# ///
"""Runs gw-eval on a history test set with personalization switched on and off, then prints paired comparisons.

usage: uv run --script eval/scripts/compare_history.py --history DIR/history.jsonl --set DIR/test.jsonl
       --model x.gguf --out DIR [--lock PATH] [--summary-only] [--resamples 10000]

Build the set with eval/scripts/build_history_set.py. Each configuration runs gw-eval --score, --typing and the
default mode (exact next word); results are cached as OUT/<model>/<set>.<mode>.<config>.json, delete one to
rerun it. With --lock, each gw-eval run first creates that directory (waiting while it exists) and removes it
afterwards, so runs that share the GPU do not overlap. Word bias changes the beam search only, so --score runs
once without and once with examples. Confidence intervals are 95%, from a paired bootstrap over rows (seed 1);
an interval that contains 0 is within noise.
"""

import argparse
import json
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_context import GW_EVAL, bootstrap  # noqa: E402

CONFIGS = {
    "baseline": [],
    "examples": ["--bias-strength", "0"],
    "bias": ["--examples", "0"],
    "both": [],
    "both-bias0.75": ["--bias-strength", "0.75"],
    "both-bias3": ["--bias-strength", "3"],
}
MODES = {"score": ["baseline", "examples"], "typing": list(CONFIGS), "next": list(CONFIGS)}


def run(args: argparse.Namespace, mode: str, config: str) -> Path:
    target = args.out / args.model.stem / f"{args.set.stem}.{mode}.{config}.json"
    if target.exists():
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    command = [str(GW_EVAL), "--set", str(args.set), "--model", str(args.model), "--json", str(target)]
    command += {"score": ["--score"], "typing": ["--typing"], "next": ["--no-warm"]}[mode]
    if config != "baseline":
        command += ["--history", str(args.history)] + CONFIGS[config]
    if args.lock:
        while True:
            try:
                args.lock.mkdir()
                break
            except FileExistsError:
                time.sleep(30)
    try:
        print("$", shlex.join(command), file=sys.stderr, flush=True)
        with target.with_suffix(".log").open("w") as handle:
            status = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT).returncode
    finally:
        if args.lock:
            args.lock.rmdir()
    if status != 0:
        print(f"failed ({status}), see {target.with_suffix('.log')}", file=sys.stderr)
    return target


def load(path: Path) -> dict[str, dict]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    return {row["id"]: row for row in (data["rows"] if isinstance(data, dict) else data)}


def bpc(rows: dict, ids: list[str]) -> float:
    return sum(rows[i]["bits"] for i in ids) / sum(rows[i]["characters"] for i in ids)


def saved(rows: dict, ids: list[str]) -> float:
    return 1 - sum(rows[i]["keystrokes"] for i in ids) / sum(rows[i]["characters"] for i in ids)


def useful(rows: dict, ids: list[str]) -> float:
    shown = sum(rows[i]["shown"] for i in ids)
    return sum(rows[i]["used"] for i in ids) / shown if shown else 0


def next_word(rows: dict, ids: list[str]) -> float:
    return sum(bool(rows[i]["exactNextWord"]) for i in ids) / len(ids)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--history", type=Path, required=True)
    parser.add_argument("--set", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--lock", type=Path)
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--resamples", type=int, default=10000)
    args = parser.parse_args()

    if not args.summary_only:
        for mode, configs in MODES.items():
            for config in configs:
                run(args, mode, config)

    def results(mode: str) -> dict[str, dict]:
        base = args.out / args.model.stem / f"{args.set.stem}.{mode}"
        return {config: load(Path(f"{base}.{config}.json")) for config in MODES[mode]}

    def table(title: str, columns: str, mode: str, value, unit: float, digits: int) -> None:
        runs = results(mode)
        base = runs["baseline"]
        print(f"\n## {args.set.name}: {title}\n")
        print(f"| config | n | {columns} | change vs baseline | 95% CI |")
        print("|---|---|---|---|---|")
        for config, rows in runs.items():
            ids = sorted(set(rows) & set(base))
            if not ids:
                continue
            delta = lambda picked: value(rows, picked) - value(base, picked)  # noqa: E731
            low, high = bootstrap(ids, delta, args.resamples)
            print(f"| {config} | {len(ids)} | {unit * value(rows, ids):.{digits}f} | {unit * delta(ids):+.{digits}f} | "
                  f"{unit * low:+.{digits}f} to {unit * high:+.{digits}f} |")

    table("bits per character of the truth (lower is better)", "bpc", "score", bpc, 1, 3)
    table("keystrokes saved, % (higher is better)", "saved", "typing", saved, 100, 1)
    table("shown suggestions used, %", "useful", "typing", useful, 100, 1)
    table("exact next word, % (higher is better)", "next word", "next", next_word, 100, 1)


if __name__ == "__main__":
    main()
