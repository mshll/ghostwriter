# /// script
# requires-python = ">=3.11"
# ///
"""Runs gw-eval --score and --typing on a set with and without its screen text, then prints paired comparisons.

usage: uv run --script eval/scripts/compare_context.py --set eval/data/context.jsonl --model x.gguf --out DIR
       [--summary-only] [--resamples 10000]

Results are cached as DIR/<model>/<set>.<score|typing>.<screen|no-screen>.json; delete a file to rerun it.
Rows with `slice: "control"` carry the screen of an unrelated thread. Confidence intervals are 95%, from a
paired bootstrap over rows (seed 1).
"""

import argparse
import json
import random
import shlex
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GW_EVAL = ROOT / "Packages/GhostwriterKit/.build/release/gw-eval"
BUCKETS = [(0, 600, "screen <600"), (600, 1800, "screen 600-1799"), (1800, 10**9, "screen >=1800")]


def run(model: Path, dataset: Path, mode: str, screen: bool, out: Path) -> Path:
    target = out / model.stem / f"{dataset.stem}.{mode}.{'screen' if screen else 'no-screen'}.json"
    if target.exists():
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    command = [str(GW_EVAL), f"--{mode}", "--set", str(dataset), "--model", str(model), "--json", str(target)]
    command += [] if screen else ["--no-screen"]
    print("$", shlex.join(command), file=sys.stderr, flush=True)
    with target.with_suffix(".log").open("w") as handle:
        status = subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT).returncode
    if status != 0:
        print(f"failed ({status}), see {target.with_suffix('.log')}", file=sys.stderr)
    return target


def load(path: Path) -> dict[str, dict]:
    return {row["id"]: row for row in json.loads(path.read_text())} if path.exists() else {}


def bucket(row: dict) -> str:
    length = len(row.get("screen") or "")
    return next(name for low, high, name in BUCKETS if low <= length < high)


def bootstrap(ids: list[str], statistic, resamples: int) -> tuple[float, float]:
    rng = random.Random(1)
    values = sorted(statistic([ids[rng.randrange(len(ids))] for _ in ids]) for _ in range(resamples))
    return values[int(0.025 * resamples)], values[int(0.975 * resamples) - 1]


def score_line(name: str, ids: list[str], on: dict, off: dict, resamples: int) -> str:
    def bpc(rows: dict, picked: list[str]) -> float:
        return sum(rows[i]["bits"] for i in picked) / sum(rows[i]["characters"] for i in picked)

    def ratio(picked: list[str]) -> float:
        return sum(on[i]["bits"] for i in picked) / sum(off[i]["bits"] for i in picked)

    low, high = bootstrap(ids, ratio, resamples)
    better = sum(on[i]["bits"] < off[i]["bits"] for i in ids)
    return (f"| {name} | {len(ids)} | {bpc(off, ids):.3f} | {bpc(on, ids):.3f} | {ratio(ids):.3f} | "
            f"{low:.3f}-{high:.3f} | {100 * better / len(ids):.0f}% |")


def typing_line(name: str, ids: list[str], on: dict, off: dict, resamples: int) -> str:
    def saved(rows: dict, picked: list[str]) -> float:
        return 1 - sum(rows[i]["keystrokes"] for i in picked) / sum(rows[i]["characters"] for i in picked)

    def gain(picked: list[str]) -> float:
        saved = sum(off[i]["keystrokes"] - on[i]["keystrokes"] for i in picked)
        return saved / sum(on[i]["characters"] for i in picked)

    def useful(rows: dict, picked: list[str]) -> float:
        shown = sum(rows[i]["shown"] for i in picked)
        return sum(rows[i]["used"] for i in picked) / shown if shown else 0

    low, high = bootstrap(ids, gain, resamples)
    return (f"| {name} | {len(ids)} | {100 * saved(off, ids):.1f}% | {100 * saved(on, ids):.1f}% | "
            f"{100 * gain(ids):+.1f} | {100 * low:+.1f} to {100 * high:+.1f} | "
            f"{100 * useful(off, ids):.1f}% | {100 * useful(on, ids):.1f}% |")


def groups(rows: dict[str, dict], ids: list[str]) -> list[tuple[str, list[str]]]:
    replies = [i for i in ids if rows[i].get("slice", "reply") == "reply"]
    controls = [i for i in ids if rows[i].get("slice") == "control"]
    out = [("all replies", replies)]
    by_lang, by_source, by_bucket = defaultdict(list), defaultdict(list), defaultdict(list)
    for i in replies:
        by_lang[rows[i].get("lang", "?")].append(i)
        by_source[rows[i].get("source", "?")].append(i)
        by_bucket[bucket(rows[i])].append(i)
    out += sorted(by_lang.items(), key=lambda item: -len(item[1]))
    out += sorted(by_source.items(), key=lambda item: -len(item[1]))
    out += [(name, by_bucket[name]) for _, _, name in BUCKETS if by_bucket[name]]
    if controls:
        pairs = [rows[i]["pair"] for i in controls]
        out += [("control: unrelated screen", controls), ("control pairs: own screen", pairs)]
        for lang in ("en", "ar"):
            subset = [i for i in controls if rows[i].get("lang") == lang]
            if subset:
                out.append((f"control {lang}", subset))
    return [(name, members) for name, members in out if members]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--resamples", type=int, default=10000)
    args = parser.parse_args()
    rows = {row["id"]: row for row in map(json.loads, args.set.read_text().splitlines()) if row}

    if not args.summary_only:
        for mode in ("score", "typing"):
            for screen in (True, False):
                run(args.model, args.set, mode, screen, args.out)

    def results(mode: str) -> tuple[dict, dict]:
        base = args.out / args.model.stem / f"{args.set.stem}.{mode}"
        return load(Path(f"{base}.screen.json")), load(Path(f"{base}.no-screen.json"))

    on, off = results("score")
    ids = sorted(set(on) & set(off) & set(rows))
    if ids:
        print(f"\n## {args.set.name}: bits per character of the truth, without vs with screen text (lower is better)\n")
        print("| rows | n | bpc without | bpc with | ratio | 95% CI | rows better |")
        print("|---|---|---|---|---|---|---|")
        for name, members in groups(rows, ids):
            print(score_line(name, members, on, off, args.resamples))

    on, off = results("typing")
    ids = sorted(set(on) & set(off) & set(rows))
    if ids:
        print(f"\n## {args.set.name}: keystrokes saved, without vs with screen text (higher is better)\n")
        print("| rows | n | saved without | saved with | gain (pp) | 95% CI | useful without | useful with |")
        print("|---|---|---|---|---|---|---|---|")
        for name, members in groups(rows, ids):
            print(typing_line(name, members, on, off, args.resamples))


if __name__ == "__main__":
    main()
