#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx>=0.27", "beautifulsoup4>=4.12", "lxml>=5"]
# ///
"""Build eval/data/context.jsonl: replies cut like the web set, each with the screen text its writer saw.

Sources are replies whose thread sits above the reply box: Hacker News comments, GitHub issue comments,
Mastodon replies, mailing-list replies and Wikipedia talk-page replies. Each row's `screen` is the text above
the box (parent comments, earlier thread, title), rendered the way the app renders window text: paragraphs
nearest the caret first, lines without content dropped, cut to 2,400 characters. Page chrome (buttons,
names, dates) is left out.

Rows have `slice: "reply"`. A control copy of half of them (`slice: "control"`, id suffix `-u`, `pair` = the
reply's id) carries the screen of another thread in the same language and source instead.

Raw downloads are cached under eval/data/raw-context/ (keyed by URL) and the window end is pinned in
eval/data/raw-context/anchor.txt on the first run, so reruns are offline and deterministic.
"""

import gzip
import hashlib
import json
import random
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from email import message_from_bytes, policy
from email.utils import parseaddr, parsedate_to_datetime
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_web_set as web  # noqa: E402

ROOT = web.ROOT
RAW = ROOT / "eval/data/raw-context"
OUT = ROOT / "eval/data/context.jsonl"
START = datetime(2026, 9, 11, tzinfo=UTC)
SEED = 20261013
UA = "ghostwriter-eval/0.1 (held-out text sampler; https://github.com/mshll/ghostwriter)"
SCREEN_CHARACTERS = 2400
ANCESTORS = 4
CONTROL_SHARE = 0.5

QUOTAS = {
    "en": [("hn", 50), ("github", 40), ("wikitalk", 25), ("mastodon", 25), ("mail", 20)],
    "ar": [("wikitalk", 115), ("mastodon", 5)],
    "es": [("wikitalk", 15), ("mastodon", 15)],
    "fr": [("wikitalk", 15), ("mastodon", 15)],
    "de": [("wikitalk", 15), ("mastodon", 15)],
    "ja": [("wikitalk", 15), ("mastodon", 15)],
    "zh": [("wikitalk", 15), ("mastodon", 15)],
}
CANDIDATES_PER_ROW = 4
web.KIND_APPS["wikitalk"] = ("form", ["Safari", "Chrome"])

WIKITALK_NAMESPACES = "1|3|4|5"
WIKITALK_MIN_BYTES = {"ja": 450, "zh": 450}
WIKITALK_RC_PAGES = 6


@dataclass
class Reply(web.Candidate):
    """A reply and the text above its reply box, in reading order."""

    thread: str = ""
    url: str = ""
    above: list[str] = field(default_factory=list)


class Fetcher(web.Fetcher):
    def __init__(self) -> None:
        super().__init__()
        self.client.headers["User-Agent"] = UA

    def _cache_path(self, source: str, key: str) -> Path:
        return RAW / source / (hashlib.sha1(key.encode()).hexdigest()[:24] + ".bin")


log = web.log


def load_anchor() -> datetime:
    path = RAW / "anchor.txt"
    if path.exists():
        return datetime.fromisoformat(path.read_text().strip())
    anchor = datetime.now(UTC).replace(minute=0, second=0, microsecond=0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(anchor.isoformat())
    return anchor


def html_paragraphs(html: str) -> str:
    soup = web.html_text(html)
    for node in soup.find_all(["style", "link", "script", "img"]):
        node.decompose()
    for br in soup.find_all("br"):
        br.replace_with("\n")
    for block in soup.find_all(["p", "li", "dd", "div", "h1", "h2", "h3", "h4", "pre", "blockquote"]):
        block.insert_before("\n")
        block.append("\n")
    return web.normalize(soup.get_text())


def typed_ok(text: str, lang: str) -> bool:
    return web.finish(text, lang) is not None


TRAILING_CLOCK = re.compile(r"\s*(?:[01]?\d|2[0-3])[:.][0-5]\d(?:\s?[AaPp]\.?[Mm]\.?)?\s*$")


def is_unsegmented(ch: str) -> bool:
    o = ord(ch)
    return (0x0E00 <= o <= 0x0EFF or 0x1000 <= o <= 0x109F or 0x1780 <= o <= 0x17FF or 0x3040 <= o <= 0x30FF
            or 0x31F0 <= o <= 0x31FF or 0x3400 <= o <= 0x4DBF or 0x4E00 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF
            or 0xFF66 <= o <= 0xFF9F or 0x20000 <= o <= 0x2FA1F)


def strip_trailing_clock(line: str) -> str:
    stripped = TRAILING_CLOCK.sub("", line)
    return line if stripped == line else stripped.strip(",·•|-–— \t")


def cleaned(text: str) -> str | None:
    lines = []
    for line in text.split("\n"):
        trimmed = strip_trailing_clock(line.strip(" \t"))
        if sum(unicodedata.category(ch).startswith(("L", "M")) for ch in trimmed) < 3:
            continue
        length = len(trimmed) + 2 * sum(is_unsegmented(ch) for ch in trimmed)
        if len(trimmed.split()) >= 2 or length >= 15:
            lines.append(trimmed)
    return "\n".join(lines) if lines else None


def normalized(text: str) -> str:
    return " ".join(text.lower().split())


def fit_end(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    if limit <= 0:
        return ""
    tail = text[-limit:]
    space = next((i for i, ch in enumerate(tail) if ch.isspace()), None)
    return tail if space is None else tail[space:].strip()


def render(above: list[str], field_text: str) -> str | None:
    paragraphs = [p for block in above for p in block.split("\n") if p.strip()]
    seen = {normalized(field_text)}
    parts, remaining = [], SCREEN_CHARACTERS
    for paragraph in reversed(paragraphs):
        if remaining <= 0:
            break
        text = cleaned(paragraph)
        if text is None:
            continue
        key = normalized(text)
        if key in seen:
            continue
        seen.add(key)
        fitted = fit_end(text, remaining)
        if not fitted:
            break
        parts.append(fitted)
        remaining -= len(fitted) + 1
    return "\n".join(parts) if parts else None



def hn_text(html: str, typed: bool) -> str:
    soup = web.html_text(html.replace("<p>", "\n"))
    if typed:
        for node in soup.find_all(["pre", "a"]):
            node.decompose()
    lines = soup.get_text().split("\n")
    if typed:
        lines = [line for line in lines if not line.lstrip().startswith(">")]
    return web.normalize("\n".join(lines))


def collect_hn(fetcher: Fetcher, start: datetime, end: datetime, quota: int) -> list[Reply]:
    hits = []
    windows = 16
    step = (end - start) / windows
    for i in range(windows):
        lo = int((start + step * i).timestamp())
        data = fetcher.json("hn", "https://hn.algolia.com/api/v1/search_by_date", {
            "tags": "comment", "numericFilters": f"created_at_i>{lo},created_at_i<{lo + 6 * 3600}", "hitsPerPage": 60,
        }, delay=0.5)
        hits += (data or {}).get("hits", [])
    hits = [hit for hit in hits if (hit.get("comment_text") or "") and not hit["comment_text"].startswith("[")]
    random.Random(f"{SEED}:hn").shuffle(hits)
    out = []
    for hit in hits:
        if len(out) >= quota * CANDIDATES_PER_ROW:
            break
        text = hn_text(hit["comment_text"], typed=True)
        if not typed_ok(text, "en"):
            continue
        chain, parent = [], hit.get("parent_id")
        story = None
        while parent and len(chain) < ANCESTORS:
            item = fetcher.json("hn", f"https://hacker-news.firebaseio.com/v0/item/{parent}.json", delay=0.2)
            if not item:
                break
            if item.get("type") == "story":
                story = item
                break
            if not item.get("deleted") and not item.get("dead"):
                chain.append(hn_text(item.get("text") or "", typed=False))
            parent = item.get("parent")
        title = hit.get("story_title") or (story or {}).get("title") or ""
        story_text = hn_text(story.get("text") or "", typed=False) if story else ""
        above = [title, story_text, *reversed(chain)] if story else list(reversed(chain))
        out.append(Reply("en", "hn", hit["objectID"], hit.get("author") or "", text, thread=f"hn:{hit.get('story_id')}",
                         url=f"https://news.ycombinator.com/item?id={hit['objectID']}", above=[a for a in above if a]))
    return out


def collect_github(fetcher: Fetcher, start: datetime, quota: int) -> list[Reply]:
    since = start.strftime("%Y-%m-%dT%H:%M:%SZ")
    picked = []
    for repo in web.GITHUB_REPOS:
        comments = fetcher.gh(f"repos/{repo}/issues/comments", {
            "sort": "created", "direction": "desc", "per_page": "60",
        }, delay=0.3) or []
        for comment in comments:
            if "/issues/" not in comment.get("html_url", "") or comment.get("created_at", "") < since:
                continue
            body = comment.get("body") or ""
            if not web.github_author_ok(comment.get("user")) or web.BOILERPLATE.search(body):
                continue
            text = web.clean_github(body)
            if typed_ok(text, "en"):
                picked.append((repo, comment, text))
    random.Random(f"{SEED}:github").shuffle(picked)
    out, per_issue = [], Counter()
    for repo, comment, text in picked:
        if len(out) >= quota * CANDIDATES_PER_ROW:
            break
        number = comment["issue_url"].rsplit("/", 1)[1]
        if per_issue[(repo, number)] >= 2:
            continue
        issue = fetcher.gh(f"repos/{repo}/issues/{number}", {}, delay=0.3)
        thread = fetcher.gh(f"repos/{repo}/issues/{number}/comments", {"per_page": "100"}, delay=0.3) or []
        if not issue or not any(c.get("id") == comment["id"] for c in thread):
            continue
        earlier = [c for c in thread if c.get("created_at", "") < comment["created_at"]]
        above = [issue.get("title") or "", web.clean_github(issue.get("body") or "")]
        above += [web.clean_github(c.get("body") or "") for c in earlier]
        per_issue[(repo, number)] += 1
        out.append(Reply("en", "github", comment["html_url"], comment["user"]["login"], text,
                         thread=f"github:{repo}#{number}", url=comment["html_url"], above=[a for a in above if a]))
    return out


def collect_mastodon(fetcher: Fetcher, start: datetime, end: datetime, wanted: dict[str, int]) -> list[Reply]:
    posts = []
    for lang, instances in web.MASTODON_INSTANCES.items():
        if not wanted.get(lang):
            continue
        points = web.MASTODON_POINTS[lang] * 2
        step = (end - start - timedelta(days=1)) / points
        for instance in instances:
            for i in range(points):
                moment = start + timedelta(days=1) + step * (i + 0.5)
                timeline = fetcher.json("mastodon", f"https://{instance}/api/v1/timelines/public", {
                    "local": "true", "limit": "40", "max_id": str(int(moment.timestamp() * 1000) << 16),
                }) or []
                posts += [(lang, instance, post) for post in timeline if post.get("in_reply_to_id")]
    if wanted.get("ar"):
        for tag in web.ARABIC_TAGS:
            timeline = fetcher.json("mastodon", f"https://{web.ARABIC_TAG_HOST}/api/v1/timelines/tag/{tag}", {
                "limit": "40", "max_id": str(int(end.timestamp() * 1000) << 16),
            }) or []
            posts += [("ar", web.ARABIC_TAG_HOST, post) for post in timeline if post.get("in_reply_to_id")]
    since = start.strftime("%Y-%m-%dT%H:%M:%S")
    by_lang = defaultdict(list)
    seen = set()
    for lang, instance, post in posts:
        if post["id"] in seen or post.get("created_at", "") < since or not web.mastodon_posts_ok(post, lang):
            continue
        seen.add(post["id"])
        text = web.clean_mastodon(post.get("content") or "")
        if typed_ok(text, lang):
            by_lang[lang].append((instance, post, text))
    out = []
    for lang, found in sorted(by_lang.items()):
        random.Random(f"{SEED}:mastodon:{lang}").shuffle(found)
        made = 0
        for instance, post, text in found:
            if made >= wanted.get(lang, 0) * CANDIDATES_PER_ROW:
                break
            context = fetcher.json("mastodon", f"https://{instance}/api/v1/statuses/{post['id']}/context") or {}
            ancestors = context.get("ancestors") or []
            if not ancestors:
                continue
            above = [html_paragraphs(a.get("content") or "") for a in ancestors[-ANCESTORS:]]
            made += 1
            author = f"{post['account']['acct']}@{instance}"
            out.append(Reply(lang, "mastodon", post["url"] or post["uri"], author, text,
                             thread=f"mastodon:{ancestors[0].get('uri')}", url=post["url"] or post["uri"],
                             above=[a for a in above if a]))
    return out


def mail_screen(body: str) -> str:
    """The message as a thread view shows it: quoted text hidden, wrapped lines joined, signature cut."""
    lines = []
    for line in body.split("\n"):
        if line.rstrip() == "--" or line.startswith("_____"):
            break
        if not line.lstrip().startswith(">") and not web.ATTRIBUTION.search(line.strip()):
            lines.append(line.rstrip())
    blocks = (" ".join(row.strip() for row in block.split("\n")) for block in re.split(r"\n\s*\n", "\n".join(lines)))
    return web.normalize("\n".join(block for block in blocks if block.strip()))


def collect_mail(fetcher: Fetcher, start: datetime, end: datetime) -> list[Reply]:
    archives = []
    for kind, url in web.MAIL_LISTS:
        if kind == "hyperkitty":
            window = {"start": f"{start:%Y-%m-%d}", "end": f"{end + timedelta(days=1):%Y-%m-%d}"}
            data = fetcher.get("mail", url, window)
            if data:
                try:
                    archives.append(gzip.decompress(data))
                except (OSError, EOFError) as error:
                    log(f"  mail: bad gzip from {url}: {error}")
        else:
            for month in sorted({f"{start:%Y-%m}", f"{end:%Y-%m}"}):
                data = fetcher.get("mail", f"{url}/{month}")
                if data:
                    archives.append(data)
    messages = {}
    for archive in archives:
        for raw in web.split_mbox(archive):
            message = message_from_bytes(raw, policy=policy.default)
            key = str(message["Message-ID"] or "").strip()
            if key:
                messages[key] = message
    out = []
    for key, message in messages.items():
        try:
            sent = parsedate_to_datetime(str(message["Date"]))
        except (TypeError, ValueError):
            continue
        if sent.tzinfo is None:
            sent = sent.replace(tzinfo=UTC)
        sender = parseaddr(str(message["From"] or ""))[1].lower()
        subject = str(message["Subject"] or "")
        parent = messages.get(str(message["In-Reply-To"] or "").strip())
        if parent is None or not start <= sent <= end:
            continue
        if web.MAIL_SKIP_SENDER.search(sender) or web.MAIL_SKIP_SUBJECT.search(subject):
            continue
        body = web.mail_body(message)
        if not body or web.BOILERPLATE.search(body):
            continue
        text = web.clean_mail(body)
        if not typed_ok(text, "en"):
            continue
        chain = []
        while parent is not None and len(chain) < ANCESTORS:
            chain.append(mail_screen(web.mail_body(parent) or ""))
            parent = messages.get(str(parent["In-Reply-To"] or "").strip())
        root = str(message["References"] or "").split()
        out.append(Reply("en", "mail", key, sender, text, thread=f"mail:{root[0] if root else key}", url=key,
                         above=[subject, *[c for c in reversed(chain) if c]]))
    return out


def thread_items(items: list[dict]) -> list[dict]:
    flat = []
    for item in items:
        flat.append(item)
        flat += thread_items(item.get("replies") or [])
    return flat


def typed_comment(html: str) -> str:
    soup = web.html_text(html)
    for node in soup.select('[typeof~="mw:Transclusion"], [about^="#mwt"], style, link, img'):
        node.decompose()
    return html_paragraphs(str(soup))


def collect_wikitalk(fetcher: Fetcher, start: datetime, end: datetime, wanted: dict[str, int]) -> list[Reply]:
    out = []
    for wiki, quota in wanted.items():
        api = f"https://{wiki}.wikipedia.org/w/api.php"
        changes, cont = [], {}
        for _ in range(WIKITALK_RC_PAGES):
            data = fetcher.json("wikipedia", api, {
                "action": "query", "list": "recentchanges", "rctype": "edit", "rcnamespace": WIKITALK_NAMESPACES,
                "rcshow": "!bot", "rctag": "discussiontools-reply", "rcprop": "title|ids|timestamp|sizes|user",
                "rclimit": "500", "rcstart": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "rcend": start.strftime("%Y-%m-%dT%H:%M:%SZ"), "format": "json", "formatversion": "2", **cont,
            }) or {}
            changes += data.get("query", {}).get("recentchanges", [])
            if "continue" not in data:
                break
            cont = {"rccontinue": data["continue"]["rccontinue"], "continue": data["continue"]["continue"]}
        minimum = WIKITALK_MIN_BYTES.get(wiki, 300)
        changes = [c for c in changes if c["newlen"] - c["oldlen"] >= minimum]
        changes.sort(key=lambda c: c["revid"])
        random.Random(f"{SEED}:wikitalk:{wiki}").shuffle(changes)
        made, authors = 0, set()
        for change in changes:
            if made >= quota * CANDIDATES_PER_ROW:
                break
            if change["user"] in authors:
                continue
            data = fetcher.json("wikipedia", api, {
                "action": "discussiontoolspageinfo", "oldid": str(change["revid"]), "prop": "threaditemshtml",
                "threaditemsflags": "excludesignatures", "format": "json", "formatversion": "2",
            }) or {}
            flat = thread_items(data.get("discussiontoolspageinfo", {}).get("threaditemshtml", []))
            minute = change["timestamp"][:16]
            mine = [i for i, item in enumerate(flat) if item.get("type") == "comment"
                    and item.get("author") == change["user"] and item.get("timestamp", "")[:16] == minute
                    and (item.get("level") or 0) >= 2]
            if len(mine) != 1:
                continue
            position = mine[0]
            text = typed_comment(flat[position].get("html") or "")
            if not typed_ok(text, wiki):
                continue
            heading = next((item for item in reversed(flat[:position]) if item.get("type") == "heading"), None)
            above = [html_paragraphs(item.get("html") or "") for item in flat[:position]]
            authors.add(change["user"])
            made += 1
            title = change["title"].replace(" ", "_")
            out.append(Reply(wiki, "wikitalk", f"{wiki}:{change['revid']}", change["user"], text,
                             thread=f"wikitalk:{wiki}:{title}#{(heading or {}).get('id', '')}",
                             url=f"https://{wiki}.wikipedia.org/w/index.php?oldid={change['revid']}",
                             above=[a for a in above if a]))
    return out



def make_rows(pools: dict[tuple[str, str], list[Reply]]) -> list[dict]:
    rows = []
    for lang, plan in QUOTAS.items():
        queues = {}
        for source, _ in plan:
            queue = list(pools.get((lang, source), []))
            random.Random(f"{SEED}:{lang}:{source}").shuffle(queue)
            queues[source] = queue

        def take(source: str) -> bool:
            while queues[source]:
                reply = queues[source].pop(0)
                row = web.make_row(reply)
                screen = render(reply.above, reply.text)
                if row and screen:
                    rows.append({**row, "screen": screen, "slice": "reply", "thread": reply.thread, "url": reply.url})
                    return True
            return False

        deficit = 0
        for source, quota in plan:
            made = 0
            while made < quota and take(source):
                made += 1
            if made < quota:
                log(f"  {lang}/{source}: {made}/{quota}, filling the gap from other {lang} sources")
            deficit += quota - made
        while deficit > 0:
            progressed = False
            for source, quota in plan:
                if deficit > 0 and quota > web.MINOR_QUOTA and take(source):
                    deficit -= 1
                    progressed = True
            if not progressed:
                log(f"  {lang}: {deficit} rows short")
                break
    random.Random(SEED).shuffle(rows)
    return [{"id": f"c{i:04d}", **row} for i, row in enumerate(rows, start=1)]


def add_controls(rows: list[dict]) -> list[dict]:
    """Copies half the rows of each language and source with the screen of the nearest-length other thread."""
    groups = defaultdict(list)
    for row in rows:
        groups[(row["lang"], row["source"])].append(row)
    controls = []
    for (lang, source), members in sorted(groups.items()):
        donors = members if len({m["thread"] for m in members}) > 1 else [r for r in rows if r["lang"] == lang]
        chosen = sorted(members, key=lambda r: r["id"])
        random.Random(f"{SEED}:control:{lang}:{source}").shuffle(chosen)
        for row in chosen[: round(len(chosen) * CONTROL_SHARE)]:
            others = [d for d in donors if d["thread"] != row["thread"]]
            if not others:
                continue
            donor = min(others, key=lambda d: (abs(len(d["screen"]) - len(row["screen"])), d["id"]))
            controls.append({**row, "id": row["id"] + "-u", "screen": donor["screen"], "slice": "control",
                             "pair": row["id"], "screen_from": donor["id"], "thread": donor["thread"]})
    return sorted(rows + controls, key=lambda r: r["id"])


def summarize(rows: list[dict], fetcher: Fetcher) -> None:
    print(f"\n{len(rows)} rows -> {OUT.relative_to(ROOT)}\n")
    print(f"{'lang':<5} {'source':<9} {'reply':>6} {'control':>8}")
    table = Counter((r["lang"], r["source"], r["slice"]) for r in rows)
    for lang in QUOTAS:
        for source in sorted({source for (row_lang, source, _) in table if row_lang == lang}):
            print(f"{lang:<5} {source:<9} {table[(lang, source, 'reply')]:>6} {table[(lang, source, 'control')]:>8}")
    print()
    columns = ["rows", "before", "truth", "insert", "screen", "<600", "<1800", ">=1800"]
    print(f"{'lang':<5} " + " ".join(f"{name:>7}" for name in columns))
    replies = [r for r in rows if r["slice"] == "reply"]
    for lang in [*QUOTAS, "all"]:
        subset = [r for r in replies if lang in ("all", r["lang"])]
        if not subset:
            continue
        screens = [len(r["screen"]) for r in subset]
        cells = [
            f"{len(subset)}", f"{sum(len(r['before']) for r in subset) / len(subset):.0f}",
            f"{sum(len(r['truth']) for r in subset) / len(subset):.1f}",
            f"{sum(bool(r['after']) for r in subset) / len(subset):.0%}", f"{sum(screens) / len(screens):.0f}",
            f"{sum(s < 600 for s in screens)}", f"{sum(600 <= s < 1800 for s in screens)}",
            f"{sum(s >= 1800 for s in screens)}",
        ]
        print(f"{lang:<5} " + " ".join(f"{cell:>7}" for cell in cells))
    print("\n(reply rows only; before/truth/screen: mean characters; insert: share of mid-line rows; "
          "last columns: rows per screen length)")
    fetched = ", ".join(f"{s} {n}" for s, n in sorted(fetcher.network.items())) or "none (all from cache)"
    print(f"network requests: {fetched}")
    if fetcher.failures:
        print("failed requests: " + ", ".join(f"{s} {n}" for s, n in sorted(fetcher.failures.items())))


def main() -> None:
    anchor = load_anchor()
    log(f"window {START:%Y-%m-%d %H:%M} .. {anchor:%Y-%m-%d %H:%M} UTC")
    fetcher = Fetcher()
    by_source = defaultdict(dict)
    for lang, plan in QUOTAS.items():
        for source, count in plan:
            by_source[source][lang] = count
    collectors = [
        ("hn", lambda: collect_hn(fetcher, START, anchor - timedelta(days=1), by_source["hn"]["en"])),
        ("github", lambda: collect_github(fetcher, START, by_source["github"]["en"])),
        ("mastodon", lambda: collect_mastodon(fetcher, START, anchor, by_source["mastodon"])),
        ("mail", lambda: collect_mail(fetcher, START, anchor)),
        ("wikitalk", lambda: collect_wikitalk(fetcher, START, anchor, by_source["wikitalk"])),
    ]
    candidates = []
    for name, collect in collectors:
        log(f"collecting {name}")
        found = collect()
        log(f"  {len(found)} replies with a thread")
        candidates += found
    pools = web.dedupe(candidates)
    for (lang, source), pool in sorted(pools.items()):
        log(f"  usable {lang}/{source}: {len(pool)}")
    rows = add_controls(make_rows(pools))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    summarize(rows, fetcher)


if __name__ == "__main__":
    main()
