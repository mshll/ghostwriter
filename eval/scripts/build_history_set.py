#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx>=0.27", "beautifulsoup4>=4.12", "lxml>=5"]
# ///
"""Build a private eval set from a copy of your own Ghostwriter database, for `gw-eval --history`.

usage: uv run --script eval/scripts/build_history_set.py COPY.sqlite [--out DIR] [--kind BUNDLE=KIND ...]
       [--history-share 0.7] [--cuts 3] [--overlap 0.5] [--seed 20261113]

Work on a copy, never on the live database:

    sqlite3 "file:$HOME/Library/Application Support/com.mshl.ghostwriter/ghostwriter.sqlite?mode=ro" \
        ".backup '$TMPDIR/ghostwriter-copy.sqlite'"

Writing sessions are split by `updatedAt`: the oldest share becomes DIR/history.jsonl (loaded into the memory
store by gw-eval), the rest DIR/test.jsonl (rows cut at word boundaries, `before` and the true continuation).
A test session whose word 5-shingles are mostly found in one history session (the same text under a new key)
is dropped. Both files hold your writing: keep them out of git (DIR defaults to eval/private/history/, which
is excluded) and never share them. The script prints counts only.

The database has no field kind, so every row gets `unknown` unless --kind maps the app's bundle ID to one of
email, chat, document, search, terminal, code, form, aiPrompt.
"""

import argparse
import json
import plistlib
import random
import re
import sqlite3
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_web_set import truth_from, truth_ok  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "eval/private/history"
SEED = 20261113
KINDS = {"email", "chat", "document", "search", "terminal", "code", "form", "aiPrompt", "unknown"}
SHINGLE = 5
MIN_BEFORE = 40
CUT_GAP = 60
ACCEPTED_KINDS = ("word", "full", "draft", "snippet")


def load_sessions(path: Path) -> list[dict]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    rows = connection.execute(
        "SELECT key, bundleID, domain, fieldLabel, text, language, updatedAt FROM writing_sessions "
        "ORDER BY updatedAt, key"
    ).fetchall()
    connection.close()
    return [dict(row) for row in rows]


def accepted_characters(path: Path, start: str, end: str) -> Counter:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    marks = ",".join("?" * len(ACCEPTED_KINDS))
    rows = connection.execute(
        f"SELECT bundleID, SUM(characters) FROM acceptance_events WHERE kind IN ({marks}) "
        "AND date >= ? AND date <= ? GROUP BY bundleID",
        (*ACCEPTED_KINDS, start, end),
    ).fetchall()
    connection.close()
    return Counter(dict(rows))


def app_name(bundle_id: str, cache: dict[str, str]) -> str:
    if bundle_id in cache:
        return cache[bundle_id]
    name = bundle_id.rsplit(".", 1)[-1]
    found = subprocess.run(
        ["mdfind", f"kMDItemCFBundleIdentifier == '{bundle_id}'"], capture_output=True, text=True
    ).stdout.split("\n")
    for app in (Path(line) for line in found if line.endswith(".app")):
        try:
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        except (OSError, plistlib.InvalidFileException) as error:
            print(f"skipping {app}: {error}", file=sys.stderr)
            continue
        name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or app.stem
        break
    cache[bundle_id] = name
    return name


def shingles(text: str) -> set[tuple[str, ...]]:
    words = re.findall(r"\w+", text.lower())
    if len(words) < SHINGLE:
        return {tuple(words)} if words else set()
    return {tuple(words[i: i + SHINGLE]) for i in range(len(words) - SHINGLE + 1)}


def containment(test: set, history: set) -> float:
    return len(test & history) / len(test) if test else 0.0


def cuts(text: str, count: int, rng: random.Random) -> list[tuple[str, str]]:
    starts = [m.start() for m in re.finditer(r"(?<= )\S", text) if m.start() >= MIN_BEFORE]
    rng.shuffle(starts)
    picked: list[tuple[str, str]] = []
    used: list[int] = []
    for cut in starts:
        if len(picked) == count:
            break
        if any(abs(cut - other) < CUT_GAP for other in used):
            continue
        truth = truth_from(text[cut:], cjk=False)
        if not truth_ok(truth, cjk=False) or not text[:cut].strip():
            continue
        picked.append((text[:cut], truth))
        used.append(cut)
    return sorted(picked, key=lambda pair: len(pair[0]))


def iso(timestamp: str) -> str:
    return datetime.fromisoformat(timestamp).isoformat(timespec="seconds") + "Z"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--kind", action="append", default=[], metavar="BUNDLE=KIND")
    parser.add_argument("--history-share", type=float, default=0.7)
    parser.add_argument("--cuts", type=int, default=3)
    parser.add_argument("--overlap", type=float, default=0.5)
    parser.add_argument("--seed", type=int, default=SEED)
    args = parser.parse_args()

    kinds = dict(pair.split("=", 1) for pair in args.kind)
    if unknown := set(kinds.values()) - KINDS:
        parser.error(f"unknown kind {sorted(unknown)}")
    rng = random.Random(args.seed)
    sessions = load_sessions(args.database)
    split = round(len(sessions) * args.history_share)
    history, tests = sessions[:split], sessions[split:]
    history_keys = {session["key"] for session in history}
    assert not any(session["key"] in history_keys for session in tests)

    history_shingles = [shingles(session["text"]) for session in history]
    names: dict[str, str] = {}
    args.out.mkdir(parents=True, exist_ok=True)
    with (args.out / "history.jsonl").open("w") as handle:
        for index, session in enumerate(history):
            handle.write(json.dumps({
                "id": f"s{index:04d}", "bundle": session["bundleID"], "domain": session["domain"],
                "label": session["fieldLabel"], "lang": session["language"], "date": iso(session["updatedAt"]),
                "text": session["text"],
            }, ensure_ascii=False) + "\n")

    dropped = 0
    rows = []
    for index, session in enumerate(tests):
        own = shingles(session["text"])
        if any(containment(own, other) >= args.overlap for other in history_shingles):
            dropped += 1
            continue
        bundle = session["bundleID"]
        for number, (before, truth) in enumerate(cuts(session["text"], args.cuts, rng)):
            rows.append({
                "id": f"t{index:04d}-{number}", "app": app_name(bundle, names), "bundle": bundle,
                "kind": kinds.get(bundle, "unknown"), "lang": session["language"], "domain": session["domain"],
                "label": session["fieldLabel"], "date": iso(session["updatedAt"]),
                "before": before, "after": "", "truth": truth,
            })
    with (args.out / "test.jsonl").open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    used_sessions = len({row["id"].split("-")[0] for row in rows})
    print(f"sessions {len(sessions)}: history {len(history)}, test {len(tests)}")
    print(f"test sessions dropped as near-duplicates of a history session (containment >= {args.overlap}): {dropped}")
    print(f"test sessions with no usable cut: {len(tests) - dropped - used_sessions}")
    print(f"test rows {len(rows)} from {used_sessions} sessions")
    print("rows by kind:", dict(Counter(row["kind"] for row in rows)))
    print("rows by language:", dict(Counter(row["lang"] or "-" for row in rows)))

    if sessions:
        recorded = Counter()
        for session in sessions:
            recorded[session["bundleID"]] += len(session["text"])
        accepted = accepted_characters(args.database, sessions[0]["updatedAt"], sessions[-1]["updatedAt"])
        share = sum(accepted.values()) / max(sum(recorded.values()), 1)
        print(f"accepted suggestion characters over the sessions' dates: {sum(accepted.values())} "
              f"of {sum(recorded.values())} recorded ({share:.1%}, an upper bound on suggested text in the sessions)")
    print(f"wrote {args.out / 'history.jsonl'} and {args.out / 'test.jsonl'}")


if __name__ == "__main__":
    main()
