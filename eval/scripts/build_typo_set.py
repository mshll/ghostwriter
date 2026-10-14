#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Build eval/data/typos.jsonl: typo-correction and proofread rows from clean writing.

Sources: eval/heldout.jsonl and eval/data/web.jsonl (build it first with build_web_set.py).

Word rows end just after a finished word, as when the writer has typed the space or punctuation after it.
"typo" rows carry one injected error, "clean" rows the same positions as written. "sentence" rows hold a
sentence with 1 to 3 injected errors. Seeded: reruns give the same file.
"""

import json
import random
import re
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [ROOT / "eval/heldout.jsonl", ROOT / "eval/data/web.jsonl"]
OUT = ROOT / "eval/data/typos.jsonl"
SEED = 20261014
LANGUAGES = ["en", "fr", "de", "es", "ar"]
WORDS_PER_LANGUAGE = 300
SENTENCES_PER_LANGUAGE = 60
MAX_POSITIONS_PER_TEXT = 6
MIN_WORDS_BEFORE = 3
MIN_WORD_LENGTH = 4
SENTENCE_WORDS = (6, 30)

LAYOUTS = {
    "en": ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
    "es": ["qwertyuiop", "asdfghjklñ", "zxcvbnm"],
    "fr": ["azertyuiop", "qsdfghjklm", "wxcvbn"],
    "de": ["qwertzuiopü", "asdfghjklöä", "yxcvbnm"],
    "ar": ["ضصثقفغعهخحجد", "شسيبلاتنمكط", "ئءؤرىةوزظ"],
}
OPERATIONS = [("substitute", 30), ("transpose", 20), ("delete", 20), ("insert", 15), ("double", 15)]

SENTENCE_ENDS = set(".!?\n。！？؟")
ATTACHED = set("@#/\\_-:$%&=+~`*")
CLOSERS = set(" \n.,!?;)\"»؟،")
CODE_HINTS = re.compile(r"https?:|www\.|[`{}<>|@#/\\_=]")
STOPWORDS = {
    "en": set("the and to of is you for that with it this my".split()),
    "fr": set("le les des et est je une pour que vous du au".split()),
    "de": set("der die das und ist ich nicht mit sie ein eine zu".split()),
    "es": set("el los que y en por para con las una del se".split()),
}


def neighbors(layout):
    rows = LAYOUTS[layout]
    result = defaultdict(set)
    for r, row in enumerate(rows):
        for i, key in enumerate(row):
            spots = [(r, i - 1), (r, i + 1), (r - 1, i), (r - 1, i + 1), (r + 1, i - 1), (r + 1, i)]
            for rr, ii in spots:
                if 0 <= rr < len(rows) and 0 <= ii < len(rows[rr]):
                    result[key].add(rows[rr][ii])
    return {key: sorted(value) for key, value in result.items()}


NEIGHBORS = {lang: neighbors(lang) for lang in LAYOUTS}


def is_word_char(text, i, in_word):
    c = text[i]
    if c.isalpha() or c.isdigit():
        return True
    return in_word and c in "'’" and i + 1 < len(text) and text[i + 1].isalpha()


def tokens(text):
    result, start = [], None
    for i in range(len(text) + 1):
        inside = i < len(text) and is_word_char(text, i, start is not None)
        if inside and start is None:
            start = i
        elif not inside and start is not None:
            result.append((start, i))
            start = None
    return result


def is_sentence_start(text, offset):
    i = offset - 1
    while i >= 0 and text[i] in " \t\"(":
        i -= 1
    return i < 0 or text[i] in SENTENCE_ENDS


def is_eligible(text, start, end):
    word = text[start:end]
    if len(word) < MIN_WORD_LENGTH or not all(c.isalpha() for c in word):
        return False
    if any(c.isupper() for c in word[1:]):
        return False
    if word[0].isupper() and not is_sentence_start(text, start):
        return False
    if start > 0 and (text[start - 1] in ATTACHED or text[start - 1] == "."):
        return False
    return True


def positions(text):
    words = tokens(text)
    found = []
    for index, (start, end) in enumerate(words):
        if index < MIN_WORDS_BEFORE or end >= len(text) or text[end] not in CLOSERS:
            continue
        line_start = text.rfind("\n", 0, start) + 1
        line_end = text.find("\n", end)
        line = text[line_start : line_end if line_end >= 0 else len(text)]
        if CODE_HINTS.search(line):
            continue
        if is_eligible(text, start, end):
            found.append((start, end))
    return found


def inject(word, lang, rng):
    keys = NEIGHBORS[lang]
    lower = word.lower()
    for _ in range(20):
        operation = rng.choices([name for name, _ in OPERATIONS], weights=[w for _, w in OPERATIONS])[0]
        chars = list(word)
        if operation == "substitute":
            spots = [i for i in range(1, len(chars)) if lower[i] in keys]
            if not spots:
                continue
            i = rng.choice(spots)
            chars[i] = rng.choice(keys[lower[i]])
        elif operation == "transpose":
            spots = [i for i in range(1, len(chars) - 1) if chars[i] != chars[i + 1]]
            if not spots:
                continue
            i = rng.choice(spots)
            chars[i], chars[i + 1] = chars[i + 1], chars[i]
        elif operation == "delete":
            i = rng.randrange(1, len(chars))
            del chars[i]
        elif operation == "insert":
            spots = [i for i in range(1, len(chars)) if lower[i] in keys]
            if not spots:
                continue
            i = rng.choice(spots)
            chars.insert(i + rng.randint(0, 1), rng.choice(keys[lower[i]]))
        else:
            i = rng.randrange(1, len(chars))
            chars.insert(i, chars[i])
        typed = unicodedata.normalize("NFC", "".join(chars))
        if typed != word:
            return typed, operation
    return None, None


def guess_language(text):
    words = re.findall(r"\w+", text.lower())
    return max(STOPWORDS, key=lambda lang: (sum(word in STOPWORDS[lang] for word in words), lang == "en"))


def load_texts():
    texts = defaultdict(list)
    for path in SOURCES:
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            lang = row.get("lang") or guess_language(row["before"] + (row.get("truth") or ""))
            if lang not in LAYOUTS:
                continue
            text = unicodedata.normalize("NFC", row["before"] + (row.get("truth") or ""))
            texts[lang].append({"id": row["id"], "app": row.get("app"), "field": row.get("kind"), "text": text})
    return texts


def word_rows(lang, sources, rng):
    candidates = []
    for source in sources:
        spots = positions(source["text"])
        rng.shuffle(spots)
        candidates += [(source, spot) for spot in spots[:MAX_POSITIONS_PER_TEXT]]
    rng.shuffle(candidates)
    rows = []
    for source, (start, end) in candidates:
        if len(rows) >= 2 * WORDS_PER_LANGUAGE:
            break
        text, word = source["text"], source["text"][start:end]
        typed, operation = inject(word, lang, rng)
        if typed is None:
            continue
        number = len(rows) // 2 + 1
        base = {"lang": lang, "app": source["app"], "field": source["field"], "source": source["id"], "truth": word}
        prefix, closer = text[:start], text[end]
        rows.append({"id": f"t-{lang}-{number:03}", "kind": "typo", "operation": operation, **base,
                     "before": prefix + typed + closer, "typed": typed})
        rows.append({"id": f"c-{lang}-{number:03}", "kind": "clean", **base, "before": prefix + word + closer, "typed": word})
    return rows


def sentences(text):
    pieces = re.split(r"(?<=[.!?؟])\s+|\n+", text)
    for piece in pieces:
        piece = piece.strip()
        count = len(piece.split())
        if SENTENCE_WORDS[0] <= count <= SENTENCE_WORDS[1] and not CODE_HINTS.search(piece):
            yield piece


def sentence_rows(lang, sources, rng):
    candidates = [(source, sentence) for source in sources for sentence in sentences(source["text"])]
    rng.shuffle(candidates)
    rows, seen = [], set()
    for source, sentence in candidates:
        if len(rows) >= SENTENCES_PER_LANGUAGE:
            break
        if sentence in seen:
            continue
        spots = [(s, e) for s, e in tokens(sentence) if is_eligible(sentence, s, e)]
        if len(spots) < 3:
            continue
        chosen = sorted(rng.sample(spots, rng.randint(1, 3)), reverse=True)
        typed = sentence
        typos = []
        for start, end in chosen:
            replacement, _ = inject(sentence[start:end], lang, rng)
            if replacement is None:
                continue
            typed = typed[:start] + replacement + typed[end:]
            typos.append({"typed": replacement, "truth": sentence[start:end]})
        if not typos:
            continue
        seen.add(sentence)
        rows.append({"id": f"s-{lang}-{len(rows) + 1:03}", "lang": lang, "kind": "sentence", "source": source["id"],
                     "text": typed, "truth": sentence, "typos": typos[::-1]})
    return rows


def main():
    texts = load_texts()
    rng = random.Random(SEED)
    rows = []
    for lang in LANGUAGES:
        rows += word_rows(lang, texts[lang], rng)
    for lang in LANGUAGES:
        rows += sentence_rows(lang, texts[lang], rng)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as out:
        for row in rows:
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
    counts = Counter((row["lang"], row["kind"]) for row in rows)
    print(f"wrote {len(rows)} rows to {OUT.relative_to(ROOT)}")
    for lang in LANGUAGES:
        print(lang, {kind: counts[(lang, kind)] for kind in ("typo", "clean", "sentence")})
    print("operations", dict(Counter(row["operation"] for row in rows if row["kind"] == "typo")))


if __name__ == "__main__":
    main()
