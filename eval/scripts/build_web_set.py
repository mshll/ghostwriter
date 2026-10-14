#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx>=0.27", "beautifulsoup4>=4.12", "lxml>=5"]
# ///
"""Build eval/data/web.jsonl: autocomplete rows cut from recent human-written web text.

Raw downloads are cached under eval/data/raw/ (keyed by URL), and the time window is pinned
in eval/data/raw/anchor.txt on the first run, so reruns are offline and deterministic.
Delete eval/data/raw/ to resample from the live sources.
"""

import gzip
import hashlib
import json
import random
import re
import subprocess
import sys
import time
import unicodedata
import zlib
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from email import message_from_bytes, policy
from email.utils import parseaddr, parsedate_to_datetime
from pathlib import Path
from urllib.parse import unquote, urlencode

import httpx
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parents[2]
RAW = ROOT / "eval/data/raw"
OUT = ROOT / "eval/data/web.jsonl"
SEED = 20261012
WINDOW_DAYS = 30
MAX_CHARS = 1500
MIN_CHARS = 120
INSERTION_SHARE = 0.15
MINOR_QUOTA = 10
WORD_BOUNDARY_SHARE = 0.65
UA = "ghostwriter-eval/0.1 (held-out text sampler; python-httpx)"
CJK = {"ja", "zh"}

QUOTAS = {
    "en": [("hn", 80), ("github", 70), ("mastodon", 60), ("wikipedia", 40), ("mail", 30)],
    "ar": [("mastodon", 10), ("wikipedia", 25), ("news", 35)],
    "es": [("mastodon", 35), ("wikipedia", 35)],
    "fr": [("mastodon", 35), ("wikipedia", 35)],
    "de": [("mastodon", 35), ("wikipedia", 35)],
    "ja": [("mastodon", 32), ("wikipedia", 32), ("github", 6)],
    "zh": [("mastodon", 32), ("wikipedia", 32), ("github", 6)],
}

MASTODON_INSTANCES = {
    "en": ["hachyderm.io", "fosstodon.org", "mas.to", "aus.social", "mastodon.ie", "sfba.social"],
    "ja": ["mstdn.jp", "mstdn.maud.io"],
    "fr": ["piaille.fr", "mamot.fr"],
    "de": ["social.tchncs.de", "chaos.social"],
    "es": ["masto.es"],
    "zh": ["o3o.ca", "c7.io", "wxw.moe", "mast.dragon-fly.club"],
}
MASTODON_POINTS = {"en": 4, "ja": 16, "fr": 6, "de": 6, "es": 10, "zh": 10}
ARABIC_TAG_HOST = "mas.to"
ARABIC_TAGS = ["عربي", "العربية", "تقنية", "برمجة", "صباح_الخير", "ماستودون", "كتب", "قراءة",
               "فلسطين", "غزة", "مصر", "السعودية", "المغرب", "لبنان", "سوريا", "الأردن"]

GITHUB_REPOS = [
    "microsoft/vscode", "neovim/neovim", "zed-industries/zed", "ollama/ollama", "ggml-org/llama.cpp",
    "home-assistant/core", "godotengine/godot", "bevyengine/bevy", "rust-lang/rust", "golang/go",
    "python/cpython", "nodejs/node", "flutter/flutter", "obsproject/obs-studio", "mastodon/mastodon",
    "tauri-apps/tauri", "helix-editor/helix", "astral-sh/uv", "oven-sh/bun", "denoland/deno",
    "immich-app/immich", "jellyfin/jellyfin", "syncthing/syncthing", "keepassxreboot/keepassxc",
    "mpv-player/mpv", "ankitects/anki", "logseq/logseq", "excalidraw/excalidraw", "rclone/rclone",
    "PrismLauncher/PrismLauncher", "wez/wezterm", "alacritty/alacritty",
]
GITHUB_CJK_TERMS = {"zh": ["请问", "感谢", "无法", "希望"], "ja": ["ください", "できません", "お願いします", "ありがとう"]}

WIKIS = ["en", "ar", "es", "fr", "de", "ja", "zh"]
WIKI_WINDOWS = 6
WIKI_FETCH = 240

NEWS_SECTIONS = {"news", "politics", "ebusiness", "science", "tech", "misc", "arts", "blogs", "opinions", "health"}
NEWS_ARTICLES = 80

MAIL_LISTS = [
    ("hyperkitty", "https://lists.fedoraproject.org/archives/list/devel@lists.fedoraproject.org/export/devel.mbox.gz"),
    ("hyperkitty", "https://lists.fedoraproject.org/archives/list/users@lists.fedoraproject.org/export/users.mbox.gz"),
    ("pipermail", "https://lists.gnu.org/archive/mbox/help-gnu-emacs"),
]

KIND_APPS = {
    "hn": ("form", ["Safari", "Chrome"]),
    "github": ("form", ["Chrome"]),
    "mastodon": ("chat", ["Messages", "Slack"]),
    "wikipedia": ("document", ["Pages", "Notes"]),
    "mail": ("email", ["Mail"]),
    "news": ("document", ["Pages", "Notes"]),
}

STOPWORDS = {
    "en": "the and of to is that it for with was this you are have not but be they what would there just my i in on at if or so we can do an as from has been will about",
    "es": "el la los las de que y en un una es por con para se del al lo como más pero su muy está yo también porque no le me hay ya eso esta este sus",
    "fr": "le la les de des et un une est que qui pour dans pas ne sur au du ce il je avec plus mais sont nous vous c'est on en à ça j'ai aux cette elle être n'est qu'il d'un d'une",
    "de": "der die das und ist nicht ich ein eine zu den mit sich auch auf für es im dem von wir sie aber wie noch oder dass bei nach wenn nur war hat sind kann mal schon man",
    "pt": "o a os as de do da dos das que e em um uma é não para com por se mais mas como foi ao na no eu isso você",
    "it": "il lo la gli le di che e è un una per non con del della sono ma come più anche ho questo nel alla",
    "nl": "de het een en van is dat niet ik je op te met voor zijn maar ook er die wat naar aan bij nog wel",
    "ca": "el la els les de que i en un una és per amb no del al però més com això molt també seu aquest",
}
STOPWORDS = {lang: set(words.split()) for lang, words in STOPWORDS.items()}

BOILERPLATE = re.compile(
    r"(?i)machine[- ]translat|translated (by|with|from|using) (deepl|google)|automatisch übersetzt|maschinell übersetzt"
    r"|traduction automatique|traduit (par|avec) deepl|traducci[oó]n autom[aá]tica|機械翻訳|机器翻译|机翻|ترجمة آلية"
    r"|(this|the) (post|message|issue|comment|report) (was|is|has been) (automatically|auto-?)(generated|created|posted)"
    r"|automated (message|post|report)|beep boop|i am a bot|generated (with|by|using) (claude|chatgpt|copilot|codex|gemini|ai\b)"
    r"|co-authored-by|🤖|Xユーザーの|クーポンコード|【PR】"
)
URL_RE = re.compile(r"https?://\S+|www\.\S+")
SPACED_URL_RE = re.compile(r"https?\s*:\s*/\s*/|\bwww\s+\.\s")
HEADLINE_RE = re.compile(r"(\s[-–—|]\s|｜)[^\s。．.!?！？]?[^。．.!?！？\n]{0,30}[^\s。．.!?！？]$")
WORD_RE = re.compile(r"(?:[^\W\d_]|[̀-ͯؐ-ًؚ-ٰٟ])+")
ZERO_WIDTH = re.compile("[​-‏‪-‮⁠-⁤﻿]")
CLOSERS = "\"'”’»)]」』）】"
ABBREVIATIONS = {"e.g.", "i.e.", "vs.", "mr.", "mrs.", "ms.", "dr.", "st.", "no.", "z.b.", "bzw.", "ca.", "sr.",
                 "sra.", "pp.", "approx.", "jr.", "a.m.", "p.m.", "p.ej.", "u.a.", "d.h."}


@dataclass
class Candidate:
    lang: str
    source: str
    key: str
    author: str
    text: str


class Fetcher:
    def __init__(self) -> None:
        self.client = httpx.Client(timeout=30, follow_redirects=True, headers={"User-Agent": UA})
        self.network = Counter()
        self.failures = Counter()

    def _cache_path(self, source: str, key: str) -> Path:
        return RAW / source / (hashlib.sha1(key.encode()).hexdigest()[:24] + ".bin")

    def get(self, source: str, url: str, params: dict | None = None, delay: float = 1.0) -> bytes | None:
        key = url + ("?" + urlencode(sorted(params.items())) if params else "")
        path = self._cache_path(source, key)
        if path.exists():
            data = path.read_bytes()
            return data or None
        for attempt in range(4):
            time.sleep(delay)
            self.network[source] += 1
            try:
                response = self.client.get(url, params=params)
            except httpx.HTTPError as error:
                log(f"  {source}: {type(error).__name__} on {url} (attempt {attempt + 1})")
                time.sleep(2 ** attempt * 2)
                continue
            if response.status_code == 200:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(response.content)
                return response.content
            if response.status_code == 429 or response.status_code >= 500:
                wait = min(float(response.headers.get("Retry-After", 2 ** attempt * 2)), 60)
                log(f"  {source}: HTTP {response.status_code} on {url}, retrying in {wait:.0f}s")
                time.sleep(wait)
                continue
            log(f"  {source}: HTTP {response.status_code} on {url}, skipping")
            self.failures[source] += 1
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"")
            return None
        self.failures[source] += 1
        return None

    def json(self, source: str, url: str, params: dict | None = None, delay: float = 1.0):
        data = self.get(source, url, params, delay)
        if data is None:
            return None
        try:
            return json.loads(data)
        except json.JSONDecodeError as error:
            log(f"  {source}: bad JSON from {url}: {error}")
            self.failures[source] += 1
            return None

    def gh(self, path: str, params: dict, delay: float) -> object | None:
        key = "gh:" + path + "?" + urlencode(sorted(params.items()))
        cache = self._cache_path("github", key)
        if cache.exists():
            data = cache.read_bytes()
            return json.loads(data) if data else None
        command = ["gh", "api", "-X", "GET", path] + [arg for k, v in params.items() for arg in ("-f", f"{k}={v}")]
        for attempt in range(4):
            time.sleep(delay)
            self.network["github"] += 1
            result = subprocess.run(command, capture_output=True, timeout=60)
            if result.returncode == 0:
                cache.parent.mkdir(parents=True, exist_ok=True)
                cache.write_bytes(result.stdout)
                return json.loads(result.stdout)
            error = result.stderr.decode(errors="replace").strip()
            if "rate limit" in error.lower() or "HTTP 5" in error or "HTTP 429" in error:
                log(f"  github: {error[:120]}, retrying")
                time.sleep(2 ** attempt * 10)
                continue
            log(f"  github: {error[:160]}, skipping {path}")
            self.failures["github"] += 1
            return None
        self.failures["github"] += 1
        return None


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def load_anchor() -> datetime:
    path = RAW / "anchor.txt"
    if path.exists():
        return datetime.fromisoformat(path.read_text().strip())
    anchor = datetime.now(UTC).replace(minute=0, second=0, microsecond=0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(anchor.isoformat())
    return anchor



def normalize(text: str) -> str:
    text = unicodedata.normalize("NFC", text)
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace(" ", " ").replace("　", " ")
    text = ZERO_WIDTH.sub("", text)
    lines = (re.sub(r"[ \t\f\v]+", " ", line).strip() for line in text.split("\n"))
    text = "\n".join(line for line in lines if line)
    text = re.sub(r" +([,.])(?=\s|$)", r"\1", text)
    text = re.sub(r",\.(?=\s|$)", ".", text)
    return re.sub(r" ?\(\s*\)", "", text)


def cap(text: str) -> str:
    if len(text) <= MAX_CHARS:
        return text
    head = text[:MAX_CHARS]
    floor = MAX_CHARS * 2 // 3
    breaks = [head.rfind(ch, floor) for ch in " \n。！？"]
    end = max(breaks)
    return head[:end].rstrip() if end > 0 else head


def script_counts(text: str) -> Counter:
    counts = Counter()
    for ch in text:
        if not ch.isalpha():
            continue
        o = ord(ch)
        if 0x3040 <= o <= 0x30FF or 0x31F0 <= o <= 0x31FF or 0xFF66 <= o <= 0xFF9F:
            counts["kana"] += 1
        elif 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0xF900 <= o <= 0xFAFF:
            counts["han"] += 1
        elif 0x0600 <= o <= 0x06FF or 0x0750 <= o <= 0x077F or 0x08A0 <= o <= 0x08FF or 0xFB50 <= o <= 0xFEFF:
            counts["arabic"] += 1
        elif o < 0x250 or 0x1E00 <= o <= 0x1EFF:
            counts["latin"] += 1
        else:
            counts["other"] += 1
    return counts


def latin_language(text: str) -> str | None:
    tokens = re.findall(r"[^\W\d_]+(?:'[^\W\d_]+)?", text.lower().replace("’", "'"))
    scores = {lang: sum(token in words for token in tokens) for lang, words in STOPWORDS.items()}
    ranked = sorted(scores.items(), key=lambda item: -item[1])
    (best, top), (_, second) = ranked[0], ranked[1]
    if top < 4 or top == second or top < 0.12 * len(tokens):
        return None
    return best


def in_language(text: str, lang: str) -> bool:
    counts = script_counts(text)
    letters = sum(counts.values())
    if letters < 40:
        return False
    if lang == "ar":
        persian = sum(text.count(ch) for ch in "پچژگکی")
        return counts["arabic"] >= 0.85 * letters and persian <= 0.01 * counts["arabic"]
    if lang in CJK:
        cjk = counts["han"] + counts["kana"]
        latin_words = len(re.findall(r"[a-zA-Z\u00c0-\u024f]+", text))
        if cjk < 0.8 * (cjk + latin_words + counts["arabic"] + counts["other"]):
            return False
        return counts["kana"] >= 0.1 * cjk if lang == "ja" else counts["kana"] <= 0.02 * cjk
    return counts["latin"] >= 0.9 * letters and latin_language(text) == lang


def is_prose(text: str, lang: str) -> bool:
    chars = [ch for ch in text if not ch.isspace()]
    if not chars:
        return False
    n = len(chars)
    letters = sum(ch.isalpha() for ch in chars)
    digits = sum(ch.isdigit() for ch in chars)
    codeish = sum(ch in "{}[]<>=;$\\|`^~" for ch in chars)
    emoji = sum(unicodedata.category(ch) == "So" for ch in chars)
    return (
        letters >= (0.62 if lang in CJK else 0.72) * n
        and digits <= 0.12 * n
        and codeish <= 0.02 * n
        and emoji <= 0.03 * n
        and not URL_RE.search(text)
        and not SPACED_URL_RE.search(text)
    )


def finish(text: str, lang: str) -> str | None:
    text = cap(normalize(text))
    if len(text) < MIN_CHARS or BOILERPLATE.search(text) or text[:40] in text[40:]:
        return None
    if len(zlib.compress(text.encode(), 9)) < 0.3 * len(text.encode()):
        return None
    if not is_prose(text, lang) or not in_language(text, lang):
        return None
    return text


def html_text(html: str) -> BeautifulSoup:
    return BeautifulSoup(html, "lxml")



def collect_hn(fetcher: Fetcher, start: datetime, end: datetime) -> list[Candidate]:
    out = []
    windows = 10
    step = (end - start) / windows
    for i in range(windows):
        lo = int((start + step * i).timestamp())
        hi = lo + 6 * 3600
        data = fetcher.json("hn", "https://hn.algolia.com/api/v1/search_by_date", {
            "tags": "comment", "numericFilters": f"created_at_i>{lo},created_at_i<{hi}", "hitsPerPage": 60,
        }, delay=0.5)
        for hit in (data or {}).get("hits", []):
            body = hit.get("comment_text") or ""
            if not body or body.startswith("["):
                continue
            soup = html_text(body.replace("<p>", "\n"))
            for node in soup.find_all(["pre", "a"]):
                node.decompose()
            lines = [line for line in soup.get_text().split("\n") if not line.lstrip().startswith(">")]
            out.append(Candidate("en", "hn", hit["objectID"], hit.get("author") or "", "\n".join(lines)))
    return out


GITHUB_BOT_LOGIN = re.compile(r"(?i)bot\b|\[bot\]|-bot|^bors$|rust-timer|rust-log-analyzer|automation|triage|engineering$")
GITHUB_LINE_DROP = re.compile(
    r"^(#|\||>|- \[[ xX]\]|\* \[[ xX]\]|_no response_|at |file \"|traceback|caused by|exception|error:|warning:|\^|\[\d|\d{4}-\d\d-\d\d|\$ |```)",
    re.IGNORECASE,
)


def clean_github(markdown: str) -> str:
    text = re.sub(r"<!--.*?-->", "", markdown, flags=re.S)
    text = re.sub(r"(```|~~~).*?(\1|$)", "\n", text, flags=re.S)
    text = re.sub(r"<details.*?</details>", "\n", text, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = URL_RE.sub("", text)
    kept = []
    for raw in text.split("\n"):
        if raw.startswith(("    ", "\t")):
            continue
        line = raw.strip()
        bare = line.replace("*", "").replace("_", "").strip()
        if not bare or GITHUB_LINE_DROP.match(line):
            continue
        if (line.startswith(("**", "__")) and line.endswith(("**", "__", "**:", ":")) and len(bare.split()) <= 8) or \
                (bare.endswith(":") and len(bare.split()) <= 6):
            continue
        if " " not in bare and len(bare) > 25:
            continue
        if len(bare.split()) < 4 and len(bare) < 25 and bare[-1] not in ".!?。！？":
            continue
        if sum(ch in "{}[]();=<>$\\/|`_*" for ch in line) > 0.12 * len(line):
            continue
        kept.append(line.replace("**", "").replace("__", ""))
    return "\n".join(kept)


def github_author_ok(user: dict | None) -> bool:
    return bool(user) and user.get("type") == "User" and not GITHUB_BOT_LOGIN.search(user.get("login", ""))


def collect_github(fetcher: Fetcher, start: datetime) -> list[Candidate]:
    out = []
    since = start.strftime("%Y-%m-%dT%H:%M:%SZ")

    def recent(item: dict) -> bool:
        return item.get("created_at", "") >= since

    for repo in GITHUB_REPOS:
        issues = fetcher.gh(f"repos/{repo}/issues", {
            "state": "all", "sort": "created", "direction": "desc", "per_page": "30",
        }, delay=0.3) or []
        for issue in issues:
            if "pull_request" in issue or not recent(issue) or not github_author_ok(issue.get("user")):
                continue
            body = issue.get("body") or ""
            if BOILERPLATE.search(body):
                continue
            out.append(Candidate("en", "github", issue["html_url"], issue["user"]["login"], clean_github(body)))
        comments = fetcher.gh(f"repos/{repo}/issues/comments", {
            "sort": "created", "direction": "desc", "per_page": "60",
        }, delay=0.3) or []
        for comment in comments:
            if "/issues/" not in comment.get("html_url", "") or not recent(comment):
                continue
            if not github_author_ok(comment.get("user")) or BOILERPLATE.search(comment.get("body") or ""):
                continue
            out.append(Candidate("en", "github", comment["html_url"], comment["user"]["login"],
                                 clean_github(comment.get("body") or "")))
    created = f"{start:%Y-%m-%d}..{start + timedelta(days=WINDOW_DAYS):%Y-%m-%d}"
    for lang, terms in GITHUB_CJK_TERMS.items():
        for term in terms:
            result = fetcher.gh("search/issues", {
                "q": f"{term} is:issue created:{created}", "per_page": "30",
            }, delay=2.5) or {}
            for issue in result.get("items", []):
                body = issue.get("body") or ""
                if not github_author_ok(issue.get("user")) or BOILERPLATE.search(body) or "@claude" in body:
                    continue
                out.append(Candidate(lang, "github", issue["html_url"], issue["user"]["login"], clean_github(body)))
    return out


def clean_mastodon(html: str) -> str:
    soup = html_text(html)
    for br in soup.find_all("br"):
        br.replace_with("\n")
    for paragraph in soup.find_all("p"):
        paragraph.append("\n")
    for anchor in soup.find_all("a"):
        label = anchor.get_text()
        if "hashtag" in (anchor.get("class") or []) or label.startswith("#"):
            anchor.replace_with("\x00" + label.lstrip("#"))
        else:
            anchor.decompose()
    lines = []
    for line in soup.get_text().split("\n"):
        line = re.sub(r"(\s*\x00\S+)+\s*$", "", line).replace("\x00", "")
        line = URL_RE.sub("", line)
        line = re.sub(r"(?<!\w)@[\w.]+(@[\w.-]+)?", "", line)
        line = re.sub(r"(?<!\w)#\w+", "", line)
        if not re.match(r"^\s*(RE|CW|cc):", line):
            lines.append(line)
    text = normalize("\n".join(lines))
    return "" if HEADLINE_RE.search(text.split("\n", 1)[0]) else text


def mastodon_posts_ok(post: dict, lang: str) -> bool:
    language = (post.get("language") or "").split("-")[0]
    account = post.get("account") or {}
    return (
        language == lang
        and not account.get("bot")
        and not post.get("spoiler_text")
        and not post.get("reblog")
        and post.get("visibility") == "public"
        and (post.get("content") or "").count('class="mention hashtag"') < 4
    )


def collect_mastodon(fetcher: Fetcher, start: datetime, end: datetime) -> list[Candidate]:
    out = []
    for lang, instances in MASTODON_INSTANCES.items():
        points = MASTODON_POINTS[lang]
        step = (end - start - timedelta(days=1)) / points
        for instance in instances:
            for i in range(points):
                moment = start + timedelta(days=1) + step * (i + 0.5)
                max_id = int(moment.timestamp() * 1000) << 16
                posts = fetcher.json("mastodon", f"https://{instance}/api/v1/timelines/public", {
                    "local": "true", "limit": "40", "max_id": str(max_id),
                }) or []
                for post in posts:
                    if mastodon_posts_ok(post, lang):
                        author = f"{post['account']['acct']}@{instance}"
                        out.append(Candidate(lang, "mastodon", post["url"] or post["uri"], author,
                                             clean_mastodon(post.get("content") or "")))
    arabic = []
    for tag in ARABIC_TAGS:
        posts = fetcher.json("mastodon", f"https://{ARABIC_TAG_HOST}/api/v1/timelines/tag/{tag}", {
            "limit": "40", "max_id": str(int(end.timestamp() * 1000) << 16),
        }) or []
        since = start.strftime("%Y-%m-%dT%H:%M:%S")
        arabic += [post for post in posts if mastodon_posts_ok(post, "ar") and post.get("created_at", "") >= since]
    per_account = Counter(post["account"]["acct"] for post in {p["uri"]: p for p in arabic}.values())
    for post in arabic:
        if per_account[post["account"]["acct"]] <= 2:
            out.append(Candidate("ar", "mastodon", post["uri"], post["account"]["acct"],
                                 clean_mastodon(post.get("content") or "")))
    return out


WIKI_SKIP_TITLE = re.compile(
    r"(?i)^(lists? of|liste |lista |listado |قائمة)|一覧|列表|年表|discograph|filmograph|diskograf|discografía"
    r"|(19|20)\d\d[–-](\d\d|(19|20)\d\d)\b|\b(season|saison|temporada|spielzeit)\b|election results"
    r"|\((disambiguation|desambiguación|homonymie|begriffsklärung|توضيح|消歧义|曖昧さ回避)\)"
)
WIKI_SKIP_TAGS = {"contenttranslation", "contenttranslation-v2", "mw-new-redirect"}


def clean_wiki(extract: str) -> str:
    kept = []
    for line in extract.split("\n"):
        line = line.strip()
        if not line or "\\displaystyle" in line:
            continue
        if line[-1] not in ".!?。！？؟:;)」" and len(line) < 80:
            continue
        if sum(ch.isdigit() for ch in line) > 0.3 * len(line):
            continue
        line = re.sub(r"[(（]\s*[;,；，、]\s*", "(", line)
        line = re.sub(r"\s*[(（]\s*[)）]", "", line)
        kept.append(line)
    return "\n".join(kept)


def collect_wikipedia(fetcher: Fetcher, start: datetime, end: datetime) -> list[Candidate]:
    out = []
    for wiki in WIKIS:
        api = f"https://{wiki}.wikipedia.org/w/api.php"
        pages = {}
        step = (end - start) / WIKI_WINDOWS
        for i in range(WIKI_WINDOWS):
            window_end = end - step * i
            data = fetcher.json("wikipedia", api, {
                "action": "query", "list": "recentchanges", "rctype": "new", "rcnamespace": "0",
                "rcshow": "!bot|!redirect", "rcprop": "title|ids|timestamp|sizes|tags|user", "rclimit": "150",
                "rcstart": window_end.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "rcend": (window_end - step).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "format": "json", "formatversion": "2",
            }) or {}
            for change in data.get("query", {}).get("recentchanges", []):
                if change.get("newlen", 0) < 4000 or WIKI_SKIP_TAGS & set(change.get("tags", [])):
                    continue
                if WIKI_SKIP_TITLE.search(change["title"]):
                    continue
                pages[change["pageid"]] = change
        chosen = sorted(pages.values(), key=lambda c: c["pageid"])
        random.Random(f"{SEED}:wiki:{wiki}").shuffle(chosen)
        creators = {change["pageid"]: change.get("user", "") for change in chosen}
        picked = [change["pageid"] for change in chosen[:WIKI_FETCH]]
        for batch in (picked[i: i + 20] for i in range(0, len(picked), 20)):
            data = fetcher.json("wikipedia", api, {
                "action": "query", "prop": "extracts|pageprops", "ppprop": "disambiguation", "exintro": "1",
                "explaintext": "1", "exlimit": "20", "pageids": "|".join(map(str, batch)),
                "format": "json", "formatversion": "2",
            }) or {}
            for page in data.get("query", {}).get("pages", []):
                if page.get("missing") or "disambiguation" in page.get("pageprops", {}):
                    continue
                text = clean_wiki(page.get("extract") or "")
                if len(text) < (200 if wiki in CJK else 400):
                    continue
                out.append(Candidate(wiki, "wikipedia", f"{wiki}:{page['pageid']}", creators[page["pageid"]], text))
    return out


def news_paragraphs(html: str, site: str) -> list[str]:
    selector = ".wysiwyg" if site == "aljazeera" else "main"
    marker = 'class="wysiwyg' if site == "aljazeera" else "<main"
    begin = html.find(marker)
    if begin < 0:
        return []
    soup = html_text(html[max(0, begin - 200): begin + 400_000])
    root = soup.select_one(selector)
    if root is None:
        return []
    paragraphs, seen = [], set()
    for node in root.find_all("p"):
        text = re.sub(r"\s+", " ", node.get_text()).strip()
        if len(text) < 50 or text[:50] in seen:
            continue
        seen.add(text[:50])
        paragraphs.append(text)
    return paragraphs


def collect_news(fetcher: Fetcher, start: datetime, end: datetime) -> list[Candidate]:
    articles = []
    base = "https://www.aljazeera.net/sitemaps/"
    sitemaps = []
    for index in ("article-archive.xml", "article-new.xml"):
        data = fetcher.get("news", base + index)
        sitemaps += re.findall(r"<loc>\s*([^<]+?)\s*</loc>", (data or b"").decode("utf-8", "replace"))
    wanted_months = {f"{d:%Y/%m}" for d in (start, end)}
    urls = set()
    for sitemap in sitemaps:
        monthly = re.search(r"article-archive/(\d{4}/\d\d)\.xml", sitemap)
        daily = re.search(r"article-new/(\d\d)-(\d\d)-(\d{4})\.xml", sitemap)
        if monthly and monthly.group(1) not in wanted_months:
            continue
        if daily:
            day = datetime(int(daily.group(3)), int(daily.group(2)), int(daily.group(1)), tzinfo=UTC)
            if not start <= day <= end:
                continue
        if not monthly and not daily:
            continue
        data = fetcher.get("news", sitemap) or b""
        for url in re.findall(r"<loc>\s*([^<]+?)\s*</loc>", data.decode("utf-8", "replace")):
            match = re.search(r"aljazeera\.net/(\w+)/(\d{4})/(\d{1,2})/(\d{1,2})/", url)
            if not match or match.group(1) not in NEWS_SECTIONS:
                continue
            day = datetime(int(match.group(2)), int(match.group(3)), int(match.group(4)), tzinfo=UTC)
            if start <= day <= end:
                urls.add(url)
    chosen = sorted(urls)
    random.Random(f"{SEED}:news").shuffle(chosen)
    for url in chosen[:NEWS_ARTICLES]:
        data = fetcher.get("news", url)
        if data:
            articles.append(("aljazeera", url, news_paragraphs(data.decode("utf-8", "replace"), "aljazeera")))
    feed = fetcher.get("news", "https://feeds.bbci.co.uk/arabic/rss.xml") or b""
    for item in re.findall(r"<item>(.*?)</item>", feed.decode("utf-8", "replace"), re.S):
        link = re.search(r"<link>([^<]+)</link>", item)
        published = re.search(r"<pubDate>([^<]+)</pubDate>", item)
        if not link or not published or "/articles/" not in link.group(1):
            continue
        if not start <= parsedate_to_datetime(published.group(1)) <= end:
            continue
        url = link.group(1).split("?")[0]
        data = fetcher.get("news", url)
        if data:
            articles.append(("bbc", url, news_paragraphs(data.decode("utf-8", "replace"), "bbc")))
    shared = Counter((site, p) for site, _, paragraphs in articles for p in set(paragraphs))
    out = []
    for site, url, paragraphs in articles:
        body = [p for p in paragraphs if shared[(site, p)] < 2]
        out.append(Candidate("ar", "news", unquote(url), url, "\n".join(body)))
    return out


MAIL_SKIP_SENDER = re.compile(r"(?i)no-?reply|automation|bodhi|koschei|mailer-daemon|notifications|releng|announce|bot@")
MAIL_SKIP_SUBJECT = re.compile(
    r"(?i)\[patch|compose report|broken dependencies|orphaned packages|ftbfs|fails to build|summary/minutes"
    r"|meeting minutes|schedule for|nightly|mass rebuild|retired packages|\bfesco\b.*(ticket|agenda)|change proposal"
)
ATTRIBUTION = re.compile(r"(?i)(wrote|writes|a écrit|schrieb|escribió)\s*:?\s*$|^on .+\d{4}.*$|^-+\s*original message")


def split_mbox(data: bytes) -> list[bytes]:
    parts = re.split(rb"(?:\A|\n)From \S+ +\w{3} \w{3} +\d+ [\d:]+ \d{4}\r?\n", data)
    return [part for part in parts if part.strip()]


def mail_body(message) -> str | None:
    try:
        part = message.get_body(preferencelist=("plain",))
        return part.get_content() if part is not None else None
    except (LookupError, ValueError, AttributeError) as error:
        log(f"  mail: undecodable body ({type(error).__name__})")
        return None


def clean_mail(body: str) -> str:
    lines = []
    for line in body.split("\n"):
        stripped = line.strip()
        if line.rstrip() == "--" or stripped.startswith("______") or re.match(r"(?i)^-+\s*original message", stripped):
            break
        if stripped.startswith(">") or ATTRIBUTION.search(stripped) or stripped in {"[...]", "[…]", "...", "…", "[snip]"}:
            continue
        lines.append(line.rstrip())
    paragraphs = []
    for block in re.split(r"\n\s*\n", "\n".join(lines)):
        rows = [row for row in block.split("\n") if row.strip()]
        if not rows:
            continue
        if sum(row.startswith(("  ", "\t")) for row in rows) > len(rows) / 2:
            continue
        joined = ""
        for row in rows:
            row = row.strip()
            joined += ("\n" if re.match(r"^([-*•]|\d+[.)])\s", row) and joined else " ") + row
        joined = joined.strip()
        if sum(ch in "{}[]();=<>$\\/|`_*" for ch in joined) > 0.06 * len(joined):
            continue
        paragraphs.append(URL_RE.sub("", joined))
    return "\n".join(paragraphs)


def collect_mail(fetcher: Fetcher, start: datetime, end: datetime) -> list[Candidate]:
    archives = []
    for kind, url in MAIL_LISTS:
        if kind == "hyperkitty":
            data = fetcher.get("mail", url, {"start": f"{start:%Y-%m-%d}", "end": f"{end + timedelta(days=1):%Y-%m-%d}"})
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
    out = []
    for archive in archives:
        for raw in split_mbox(archive):
            message = message_from_bytes(raw, policy=policy.default)
            try:
                sent = parsedate_to_datetime(str(message["Date"]))
            except (TypeError, ValueError):
                continue
            if sent.tzinfo is None:
                sent = sent.replace(tzinfo=UTC)
            sender = parseaddr(str(message["From"] or ""))[1].lower()
            subject = str(message["Subject"] or "")
            if not start <= sent <= end or MAIL_SKIP_SENDER.search(sender) or MAIL_SKIP_SUBJECT.search(subject):
                continue
            body = mail_body(message)
            if not body or BOILERPLATE.search(body):
                continue
            key = str(message["Message-ID"] or f"{sender}:{sent.isoformat()}")
            out.append(Candidate("en", "mail", key, sender, clean_mail(body)))
    return out



def ends_sentence(token: str) -> bool:
    core = token.rstrip(CLOSERS)
    if not core:
        return False
    if core[-1] in "!?؟。！？…":
        return True
    if core[-1] != ".":
        return False
    return core.lower() not in ABBREVIATIONS and not re.fullmatch(r"([^\W\d_]\.)+|\d{1,2}\.", core)


def truth_from(rest: str, cjk: bool) -> str:
    line = rest.split("\n", 1)[0]
    if cjk:
        for i, ch in enumerate(line[:60]):
            following = line[i + 1: i + 2]
            if ch in "。！？!?…" or (ch == "." and following in ("", " ")):
                return line[: i + 1]
        return line[:60]
    for count, match in enumerate(re.finditer(r"\S+", line), start=1):
        if ends_sentence(match.group()) or count == 12:
            return line[: match.end()]
    return line.rstrip()


def truth_ok(truth: str, cjk: bool) -> bool:
    return len(re.sub(r"\s", "", truth)) >= 4 if cjk else len(truth.split()) >= 2


def safe_cut(text: str, cut: int) -> int:
    while 0 < cut < len(text) and unicodedata.category(text[cut]).startswith("M"):
        cut += 1
    return cut


def boundary_cut(text: str, pos: int) -> int | None:
    for distance in range(80):
        for cut in (pos - distance, pos + distance):
            if 0 < cut < len(text) and text[cut - 1] == " " and not text[cut].isspace():
                return cut
    return None


def midword_cut(text: str, pos: int, rng: random.Random) -> int | None:
    words = [m for m in WORD_RE.finditer(text) if len(m.group()) >= 4]
    if not words:
        return None
    word = min(words, key=lambda m: abs(m.start() - pos))
    return word.start() + rng.randint(1, len(word.group()) - 2)


def continuation(text: str, lang: str, rng: random.Random) -> tuple[str, str, str] | None:
    cjk = lang in CJK
    for _ in range(10):
        pos = int(len(text) * rng.uniform(0.35, 0.85))
        if cjk:
            cut = pos
        elif rng.random() < WORD_BOUNDARY_SHARE:
            cut = boundary_cut(text, pos)
        else:
            cut = midword_cut(text, pos, rng)
        if cut is None:
            continue
        cut = safe_cut(text, cut)
        truth = truth_from(text[cut:], cjk)
        if truth_ok(truth, cjk):
            return text[:cut], "", truth
    return None


def insertion(text: str, lang: str, rng: random.Random) -> tuple[str, str, str] | None:
    cjk = lang in CJK
    for _ in range(10):
        pos = int(len(text) * rng.uniform(0.35, 0.85))
        line_start = text.rfind("\n", 0, pos) + 1
        line_end = text.find("\n", pos)
        line_end = len(text) if line_end < 0 else line_end
        if cjk:
            start = safe_cut(text, pos)
            end = safe_cut(text, start + rng.randint(4, 10))
            span = text[start:end]
            if start - line_start < 3 or line_end - end < 3 or any(ch in "。！？!?…\n" for ch in span):
                continue
            if not truth_ok(span, cjk):
                continue
            return text[:start], text[end:], span
        tokens = list(re.finditer(r"\S+", text[line_start:line_end]))
        if len(tokens) < 4:
            continue
        rel = pos - line_start
        j = min(range(len(tokens)), key=lambda k: abs(tokens[k].start() - rel))
        n = rng.randint(1, 4)
        if j < 1 or j + n >= len(tokens):
            continue
        span = tokens[j: j + n]
        if any(ends_sentence(token.group()) for token in span):
            continue
        span_end = line_start + span[-1].end()
        if rng.random() < WORD_BOUNDARY_SHARE:
            start = line_start + tokens[j - 1].end()
        else:
            letters = WORD_RE.match(span[0].group())
            if not letters or len(letters.group()) < 4:
                continue
            start = safe_cut(text, line_start + span[0].start() + rng.randint(1, len(letters.group()) - 2))
        if start >= span_end:
            continue
        return text[:start], text[span_end:], text[start:span_end]
    return None


def make_row(candidate: Candidate) -> dict | None:
    rng = random.Random(f"{SEED}:{candidate.source}:{candidate.key}")
    kind, apps = KIND_APPS[candidate.source]
    if candidate.source == "news" and rng.random() < 1 / 3:
        kind, apps = "email", ["Mail"]
    app = rng.choice(apps)
    cut = None
    if rng.random() < INSERTION_SHARE:
        cut = insertion(candidate.text, candidate.lang, rng)
    cut = cut or continuation(candidate.text, candidate.lang, rng)
    if cut is None:
        return None
    before, after, truth = cut
    if not before.strip() or not truth.strip() or "\n" in truth:
        return None
    return {"app": app, "kind": kind, "lang": candidate.lang, "source": candidate.source,
            "before": before, "after": after, "truth": truth}



def dedupe(candidates: list[Candidate]) -> dict[tuple[str, str], list[Candidate]]:
    pools = defaultdict(list)
    seen_text, seen_prefix, seen_author = set(), set(), set()
    dropped = Counter()
    for candidate in candidates:
        text = finish(candidate.text, candidate.lang)
        if text is None:
            dropped[(candidate.lang, candidate.source, "filtered")] += 1
            continue
        prefix = re.sub(r"\s+", " ", text[:80].lower())
        author = (candidate.source, candidate.author)
        if text in seen_text or prefix in seen_prefix:
            dropped[(candidate.lang, candidate.source, "duplicate")] += 1
            continue
        if candidate.source != "news" and candidate.author and author in seen_author:
            dropped[(candidate.lang, candidate.source, "same author")] += 1
            continue
        seen_text.add(text)
        seen_prefix.add(prefix)
        seen_author.add(author)
        candidate.text = text
        pools[(candidate.lang, candidate.source)].append(candidate)
    for (lang, source, reason), count in sorted(dropped.items()):
        log(f"  dropped {lang}/{source}: {count} {reason}")
    return pools


def select(pools: dict[tuple[str, str], list[Candidate]]) -> list[dict]:
    rows = []
    for lang, plan in QUOTAS.items():
        queues = {}
        for source, _ in plan:
            queue = list(pools.get((lang, source), []))
            random.Random(f"{SEED}:{lang}:{source}").shuffle(queue)
            queues[source] = queue

        def take(source: str) -> bool:
            while queues[source]:
                row = make_row(queues[source].pop(0))
                if row:
                    rows.append(row)
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
                if deficit > 0 and quota > MINOR_QUOTA and take(source):
                    deficit -= 1
                    progressed = True
            if not progressed:
                log(f"  {lang}: {deficit} rows short")
                break
    random.Random(SEED).shuffle(rows)
    return [{"id": f"w{i:04d}", **row} for i, row in enumerate(rows, start=1)]


def summarize(rows: list[dict], fetcher: Fetcher, skipped: list[str]) -> None:
    table = Counter((r["lang"], r["source"], r["kind"]) for r in rows)
    print(f"\n{len(rows)} rows -> {OUT.relative_to(ROOT)}\n")
    print(f"{'lang':<5} {'source':<10} {'kind':<9} {'rows':>5}")
    for (lang, source, kind), count in sorted(table.items(), key=lambda item: (list(QUOTAS).index(item[0][0]), item[0])):
        print(f"{lang:<5} {source:<10} {kind:<9} {count:>5}")
    print()
    print(f"{'lang':<5} {'rows':>5} {'before':>7} {'truth':>6} {'insert':>7}")
    for lang in [*QUOTAS, "all"]:
        subset = [r for r in rows if lang in ("all", r["lang"])]
        if not subset:
            continue
        mean_before = sum(len(r["before"]) for r in subset) / len(subset)
        mean_truth = sum(len(r["truth"]) for r in subset) / len(subset)
        inserts = sum(bool(r["after"]) for r in subset) / len(subset)
        print(f"{lang:<5} {len(subset):>5} {mean_before:>7.0f} {mean_truth:>6.1f} {inserts:>7.0%}")
    print("\n(before/truth: mean length in characters; insert: share of mid-line insertion rows)")
    fetched = ", ".join(f"{s} {n}" for s, n in sorted(fetcher.network.items())) or "none (all from cache)"
    print(f"network requests: {fetched}")
    if fetcher.failures:
        print("failed requests: " + ", ".join(f"{s} {n}" for s, n in sorted(fetcher.failures.items())))
    for line in skipped:
        print(f"skipped source: {line}")


def main() -> None:
    anchor = load_anchor()
    start = anchor - timedelta(days=WINDOW_DAYS)
    log(f"window {start:%Y-%m-%d %H:%M} .. {anchor:%Y-%m-%d %H:%M} UTC")
    fetcher = Fetcher()
    collectors = [
        ("hn", lambda: collect_hn(fetcher, start, anchor - timedelta(days=1))),
        ("github", lambda: collect_github(fetcher, start)),
        ("mastodon", lambda: collect_mastodon(fetcher, start, anchor)),
        ("wikipedia", lambda: collect_wikipedia(fetcher, start, anchor)),
        ("news", lambda: collect_news(fetcher, start, anchor)),
        ("mail", lambda: collect_mail(fetcher, start, anchor)),
    ]
    candidates, skipped = [], []
    for name, collect in collectors:
        log(f"collecting {name}")
        found = collect()
        log(f"  {len(found)} raw texts")
        if not found:
            skipped.append(f"{name} (no texts; see log above)")
        candidates += found
    pools = dedupe(candidates)
    for (lang, source), pool in sorted(pools.items()):
        log(f"  usable {lang}/{source}: {len(pool)}")
    rows = select(pools)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    summarize(rows, fetcher, skipped)


if __name__ == "__main__":
    main()
