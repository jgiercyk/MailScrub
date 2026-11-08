#!/usr/bin/env python3
"""MailScrub engine: IMAP spam quarantine with allow/block rules, heuristics and review logging.

Usage:
  python -X utf8 mailscrub.py survey             read-only sender-domain histogram of the source folder
  python -X utf8 mailscrub.py scan               apply rules; moves mail unless settings.dry_run
  python -X utf8 mailscrub.py digest             new sender domains since the last digest
  python -X utf8 mailscrub.py purge-quarantine   delete quarantined mail older than retention
  python -X utf8 mailscrub.py test-connection    verify credentials, folders and optional dependencies
  python -X utf8 mailscrub.py config-get         rules.yaml (with defaults applied) as JSON
  python -X utf8 mailscrub.py config-set FILE    JSON file -> rules.yaml
  python -X utf8 mailscrub.py review-apply FILE  {"allow": [addresses], "block": [addresses]}
  python -X utf8 mailscrub.py cred-get           connection details as JSON, password omitted
  python -X utf8 mailscrub.py cred-set FILE      {"host","port","user","pass"} -> credentials.json (DPAPI)

Credentials: env MAILSCRUB_HOST / MAILSCRUB_USER / MAILSCRUB_PASS [/ MAILSCRUB_PORT] take priority,
otherwise credentials.json next to this file. The password there is DPAPI-encrypted to the Windows
account that saved it ("pass_dpapi"); a legacy plaintext "pass" key still works but is warned about.
Set MAILSCRUB_HOME to run against a different data folder (used by the tests).
"""
import base64
import ctypes
import email
import email.header
import hashlib
import html
import imaplib
import json
import os
import re
import socket
import sys
import time
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from email.utils import parseaddr
from functools import lru_cache
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("MailScrub needs PyYAML: python -m pip install pyyaml")

try:
    from langdetect import detect_langs, DetectorFactory
    DetectorFactory.seed = 0
    HAVE_LANGDETECT = True
except ImportError:
    HAVE_LANGDETECT = False

# ---------------------------------------------------------------- constants (protocol / tuning)
IMAP_PORT_DEFAULT = 993
IMAP_TIMEOUT_S = 60            # socket timeout for every IMAP call; a stalled server fails fast
IMAP_FETCH_BATCH = 200         # header fetch chunk size
BODY_FETCH_BYTES = 65536       # partial fetch: enough for the text parts, skips attachments
BODY_TEXT_MAX = 20000          # characters of stripped text handed to the classifier
UNSUB_TIMEOUT_S = 10
UNSUB_USER_AGENT = "MailScrub/1.1"
KEEP_CACHE_MAX = 5000          # message-ids remembered as "keep"; oldest evicted first
LOG_MAX_BYTES = 2_000_000
LOG_BACKUPS = 5
LOCK_STALE_S = 40 * 60         # a lock older than this belongs to a killed run and is overridden
QUARANTINE_RECORD_GRACE_DAYS = 7   # keep quarantined-msgid records this long past retention
# language detection
LANG_MIN_WORDS = 12            # below this, do not guess
HEAD_WORDS = 200               # judge the opening of the message, before any English boilerplate footer
EN_STOP_RATIO = 0.05           # share of English function words that settles "English" when the detector is unsure
EN_STOP_RATIO_SURE = 0.10      # share that settles "English" even against a confident detector
SOUP_MAX_WORDS = 60            # short brand-name lists with no sentences: do not guess...
SOUP_MIN_CONF = 0.98           # ...unless the detector is this sure
NON_LATIN_MIN = 10
NON_LATIN_RATIO = 0.2
BULK_PRECEDENCE = ("bulk", "list", "junk")
HDR_FIELDS = "FROM SUBJECT LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST PRECEDENCE LIST-ID MESSAGE-ID CONTENT-LANGUAGE"

DEFAULTS = {
    "allow": [],
    "block": [],
    "heuristics": {
        "enabled": True,
        "quarantine_if_list_unsubscribe": True,
        "quarantine_if_precedence_bulk": True,
        "quarantine_if_subscription_confirm": True,
        "quarantine_if_unsubscribe_link": True,
        "weight_list_unsubscribe": 1,
        "weight_precedence": 1,
        "weight_list_id": 1,
        "weight_subscription_confirm": 2,
        "unsubscribe_link_weight": 2,
        "min_score": 2,
    },
    "language": {"enabled": True, "allowed": ["en"], "min_confidence": 0.85, "action": "delete"},
    "unsubscribe": {"enabled": True},
    "settings": {
        "source_folder": "INBOX",
        "quarantine_folder": "Quarantine",
        "trash_folder": "Trash",
        "delete_to_trash": True,
        "quarantine_retention_days": 14,
        "learn_from_restores": True,
        "dry_run": True,
        "rescan_all": False,
        "scan_every_minutes": 15,
    },
}
RULES_HEADER = ("# MailScrub rules. Managed by MailScrubGui; hand edits are fine too.\n"
                "# Patterns are Python regexes, case-insensitive. Missing keys take the engine defaults.\n\n")

# ---------------------------------------------------------------- paths
HERE = RULES = LOG = STATE = REVIEW = SURVEY = CREDS = LOCK = None


def set_home(folder):
    """Point all data files at `folder`. Called once at import; tests call it again."""
    global HERE, RULES, LOG, STATE, REVIEW, SURVEY, CREDS, LOCK
    HERE = Path(folder)
    RULES, LOG, STATE = HERE / "rules.yaml", HERE / "scrub.log", HERE / "state.json"
    REVIEW, SURVEY, CREDS, LOCK = HERE / "review.json", HERE / "survey.json", HERE / "credentials.json", HERE / "scan.lock"


set_home(os.environ.get("MAILSCRUB_HOME") or Path(__file__).parent)


class ConfigError(Exception):
    """Bad or missing configuration. Reported plainly, exit code 2."""


class LockError(Exception):
    """Another scan holds the lock."""


# ---------------------------------------------------------------- files, logging, state
def atomic_write(path, text):
    """Write via a temp file in the same directory and rename, so a killed process never leaves a torn file."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def rotate_log():
    if not LOG.exists() or LOG.stat().st_size < LOG_MAX_BYTES:
        return
    for i in range(LOG_BACKUPS - 1, 0, -1):
        src, dst = LOG.with_suffix(f".log.{i}"), LOG.with_suffix(f".log.{i + 1}")
        if src.exists():
            os.replace(src, dst)
    os.replace(LOG, LOG.with_suffix(".log.1"))


def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line, flush=True)
    rotate_log()
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def fresh_state():
    return {"seen_domains": {}, "learned_allow": [], "quarantined": {}, "scanned_msgids": [],
            "unsubscribed": {}, "last_digest": None, "rules_fingerprint": None}


def load_state():
    if not STATE.exists():
        return fresh_state()
    try:
        st = json.loads(STATE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise ConfigError(f"{STATE} is not valid JSON ({e}). Restore it from {STATE.name}.bak before scanning again.")
    for k, v in fresh_state().items():
        st.setdefault(k, v)
    # migration: quarantined used to map msgid -> sender; now msgid -> {"from", "when"}
    for mid, v in list(st["quarantined"].items()):
        if isinstance(v, str):
            st["quarantined"][mid] = {"from": v, "when": datetime.now().isoformat()}
    return st


def save_state(st):
    if STATE.exists():
        try:
            os.replace(STATE, STATE.with_suffix(".json.bak"))
        except OSError as e:
            log(f"warning: could not keep state backup: {e}")
    atomic_write(STATE, json.dumps(st, indent=2, ensure_ascii=False))


class ScanLock:
    """One scan at a time per data folder (the scheduled task and the GUI share state.json)."""

    def __enter__(self):
        if LOCK.exists():
            age = time.time() - LOCK.stat().st_mtime
            if age < LOCK_STALE_S:
                raise LockError(f"another scan started {int(age)}s ago is still running ({LOCK}). "
                                f"If you are sure it is dead, delete that file.")
            log(f"stale lock from a killed run ({int(age)}s old) overridden")
        LOCK.write_text(f"{os.getpid()} {datetime.now().isoformat()}", encoding="utf-8")
        return self

    def __exit__(self, *exc):
        try:
            LOCK.unlink()
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------- rules
def deep_merge(defaults, override):
    out = dict(defaults)
    for k, v in (override or {}).items():
        out[k] = deep_merge(defaults[k], v) if isinstance(v, dict) and isinstance(defaults.get(k), dict) else v
    return out


@lru_cache(maxsize=4096)
def rx(pattern):
    return re.compile(pattern, re.I)


def validate_rules(rules):
    for section in ("allow", "block"):
        for i, r in enumerate(rules[section], 1):
            if not isinstance(r, dict) or not ({"from", "subject"} & r.keys()):
                raise ConfigError(f"{section} rule {i} must have a 'from' and/or 'subject' pattern: {r!r}")
            for key in ("from", "subject"):
                if key in r:
                    if not isinstance(r[key], str):
                        raise ConfigError(f"{section} rule {i}: '{key}' must be a string, got {r[key]!r}")
                    try:
                        rx(r[key])
                    except re.error as e:
                        raise ConfigError(f"{section} rule {i}: invalid regex in '{key}' ({e}): {r[key]!r}")
    lang = rules["language"]
    if lang["action"] not in ("delete", "quarantine"):
        raise ConfigError(f"language.action must be 'delete' or 'quarantine', got {lang['action']!r}")
    if not 0 < float(lang["min_confidence"]) <= 1:
        raise ConfigError(f"language.min_confidence must be in (0, 1], got {lang['min_confidence']!r}")
    if not isinstance(lang["allowed"], list) or not lang["allowed"]:
        raise ConfigError("language.allowed must be a non-empty list of ISO codes")
    s = rules["settings"]
    if int(s["quarantine_retention_days"]) < 1:
        raise ConfigError("settings.quarantine_retention_days must be at least 1")
    for key in ("source_folder", "quarantine_folder", "trash_folder"):
        if not str(s[key]).strip():
            raise ConfigError(f"settings.{key} must not be empty")
    if s["source_folder"] == s["quarantine_folder"]:
        raise ConfigError("settings.source_folder and settings.quarantine_folder must differ")
    if int(rules["heuristics"]["min_score"]) < 1:
        raise ConfigError("heuristics.min_score must be at least 1")


def load_rules():
    if not RULES.exists():
        raise ConfigError(f"{RULES} not found. Create it from the GUI or copy the sample from CLAUDE.md.")
    try:
        raw = yaml.safe_load(RULES.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as e:
        raise ConfigError(f"{RULES} is not valid YAML: {e}")
    if not isinstance(raw, dict):
        raise ConfigError(f"{RULES} must be a mapping at the top level")
    rules = deep_merge(DEFAULTS, raw)
    rules["allow"] = list(rules["allow"] or [])
    rules["block"] = list(rules["block"] or [])
    validate_rules(rules)
    return rules


def write_rules(rules):
    atomic_write(RULES, RULES_HEADER + yaml.safe_dump(rules, sort_keys=False, allow_unicode=True,
                                                      default_flow_style=False, width=1000))


# ---------------------------------------------------------------- credentials (DPAPI)
class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_uint32), ("pbData", ctypes.POINTER(ctypes.c_byte))]


def _blob(data):
    buf = ctypes.create_string_buffer(data, len(data))
    return _DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_byte))), buf


def _dpapi(func, data):
    inp, keep_alive = _blob(data)
    out = _DATA_BLOB()
    if not func(ctypes.byref(inp), None, None, None, None, 0, ctypes.byref(out)):
        raise OSError(f"DPAPI call failed ({ctypes.GetLastError()})")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out.pbData)


def dpapi_protect(text):
    """Encrypt for the current Windows user; returns base64."""
    return base64.b64encode(_dpapi(ctypes.windll.crypt32.CryptProtectData, text.encode("utf-8"))).decode("ascii")


def dpapi_unprotect(b64):
    return _dpapi(ctypes.windll.crypt32.CryptUnprotectData, base64.b64decode(b64)).decode("utf-8")


def creds():
    """(host, user, password, port). Env vars win; otherwise credentials.json."""
    if os.environ.get("MAILSCRUB_HOST"):
        try:
            return (os.environ["MAILSCRUB_HOST"], os.environ["MAILSCRUB_USER"], os.environ["MAILSCRUB_PASS"],
                    int(os.environ.get("MAILSCRUB_PORT", IMAP_PORT_DEFAULT)))
        except KeyError as e:
            raise ConfigError(f"MAILSCRUB_HOST is set but {e.args[0]} is missing")
    if not CREDS.exists():
        raise ConfigError(f"No credentials: save them from the GUI Connection tab or set MAILSCRUB_HOST/USER/PASS")
    try:
        d = json.loads(CREDS.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise ConfigError(f"{CREDS} is not valid JSON: {e}")
    for key in ("host", "user"):
        if not d.get(key):
            raise ConfigError(f"{CREDS} is missing '{key}'")
    if d.get("pass_dpapi"):
        try:
            pw = dpapi_unprotect(d["pass_dpapi"])
        except Exception as e:
            raise ConfigError(f"could not decrypt the stored password (saved by a different Windows account?): {e}")
    elif d.get("pass"):
        pw = d["pass"]
        log("warning: credentials.json holds a plaintext password; re-save it from the Connection tab to encrypt it")
    else:
        raise ConfigError(f"{CREDS} has no password; save credentials from the Connection tab")
    return d["host"], d["user"], pw, int(d.get("port") or IMAP_PORT_DEFAULT)


def cmd_cred_get():
    out = {"host": "", "port": IMAP_PORT_DEFAULT, "user": "", "has_password": False, "encrypted": False}
    if CREDS.exists():
        try:
            d = json.loads(CREDS.read_text(encoding="utf-8"))
            out.update(host=d.get("host", ""), port=int(d.get("port") or IMAP_PORT_DEFAULT), user=d.get("user", ""),
                       has_password=bool(d.get("pass_dpapi") or d.get("pass")), encrypted=bool(d.get("pass_dpapi")))
        except (json.JSONDecodeError, ValueError):
            out["error"] = f"{CREDS.name} is unreadable"
    print(json.dumps(out))


def cmd_cred_set():
    """argv[2] = JSON file with host, port, user, pass. The file is deleted after reading."""
    src = Path(sys.argv[2])
    d = json.loads(src.read_text(encoding="utf-8"))
    try:
        src.unlink()
    except OSError:
        pass
    for key in ("host", "user"):
        if not str(d.get(key, "")).strip():
            raise ConfigError(f"'{key}' is required")
    port = int(d.get("port") or IMAP_PORT_DEFAULT)
    if not 1 <= port <= 65535:
        raise ConfigError(f"port out of range: {port}")
    rec = {"host": d["host"].strip(), "port": port, "user": d["user"].strip()}
    pw = d.get("pass") or ""
    if pw:
        rec["pass_dpapi"] = dpapi_protect(pw)
    elif CREDS.exists():
        old = json.loads(CREDS.read_text(encoding="utf-8"))
        if old.get("pass_dpapi"):
            rec["pass_dpapi"] = old["pass_dpapi"]
        elif old.get("pass"):
            rec["pass_dpapi"] = dpapi_protect(old["pass"])   # upgrade legacy plaintext in place
    if "pass_dpapi" not in rec:
        raise ConfigError("no password given and none stored")
    atomic_write(CREDS, json.dumps(rec, indent=2))
    print("credentials saved; password encrypted with DPAPI for this Windows account")


# ---------------------------------------------------------------- IMAP
def connect():
    host, user, pw, port = creds()
    try:
        m = imaplib.IMAP4_SSL(host, port, timeout=IMAP_TIMEOUT_S)
        m.login(user, pw)
    except (socket.gaierror, socket.timeout, ConnectionError, OSError) as e:
        raise ConfigError(f"cannot reach IMAP server {host}:{port}: {e}")
    except imaplib.IMAP4.error as e:
        raise ConfigError(f"IMAP login failed for {user} at {host}: {e}")
    return m


def dec(s):
    if not s:
        return ""
    try:
        return str(email.header.make_header(email.header.decode_header(s)))
    except Exception:   # malformed encoded-word: the raw header is still useful for matching
        return str(s)


def folder_names(m):
    typ, data = m.list()
    names = []
    for d in data or []:
        if not d:
            continue
        mt = re.search(rb'(?:"([^"]*)"|(\S+))\s*$', d)
        if mt:
            names.append((mt.group(1) or mt.group(2)).decode("utf-8", "replace"))
    return names


def resolve_folder(m, name, create=False):
    """Return the server's name for `name` (tries INBOX.name too). Optionally create it."""
    names = folder_names(m)
    for cand in (name, f"INBOX.{name}", f"INBOX/{name}"):
        if cand in names:
            return cand
    if create:
        typ, _ = m.create(name)
        if typ != "OK":
            raise ConfigError(f"could not create folder {name!r}")
        log(f"created folder {name}")
        return name
    return None


def fetch_headers(m, folder):
    typ, _ = m.select(folder, readonly=True)
    if typ != "OK":
        raise ConfigError(f"cannot open folder {folder!r}")
    typ, data = m.uid("SEARCH", None, "ALL")
    uids = data[0].split()
    out = []
    for i in range(0, len(uids), IMAP_FETCH_BATCH):
        chunk = b",".join(uids[i:i + IMAP_FETCH_BATCH])
        typ, resp = m.uid("FETCH", chunk, f"(BODY.PEEK[HEADER.FIELDS ({HDR_FIELDS})])")
        for part in resp:
            if not isinstance(part, tuple):
                continue
            mt = re.search(rb"UID (\d+)", part[0])
            if not mt:
                continue
            msg = email.message_from_bytes(part[1])
            out.append({
                "uid": mt.group(1).decode(),
                "from": parseaddr(dec(msg.get("From")))[1].lower(),
                "subject": dec(msg.get("Subject")),
                "msgid": (msg.get("Message-ID") or "").strip(),
                "list_unsub": bool(msg.get("List-Unsubscribe")),
                "list_unsub_raw": msg.get("List-Unsubscribe") or "",
                "list_unsub_post": msg.get("List-Unsubscribe-Post") or "",
                "list_id": bool(msg.get("List-Id")),
                "precedence": (msg.get("Precedence") or "").lower(),
                "content_language": msg.get("Content-Language") or "",
            })
    return out


# Zero-width / filler characters that marketers pad preheaders with. Combining marks used by
# real scripts (e.g. Devanagari vowel signs) are deliberately NOT in this list.
INVISIBLE = re.compile(r"[­͏؜ᅟᅠ឴឵᠎​-‏‪-‮⁠-⁯﻿︀-️ ]+")


def html_to_text(t):
    t = re.sub(r"<!--.*?-->", " ", t, flags=re.S)
    t = re.sub(r"<(script|style).*?</\1>", " ", t, flags=re.S | re.I)
    t = re.sub(r"<(script|style)[^>]*>[^<]*", " ", t, flags=re.I)        # unterminated block: drop up to the next tag
    t = re.sub(r"<[^>]+>", " ", t)
    t = html.unescape(t)          # &zwnj; &#847; &nbsp; become real characters...
    return INVISIBLE.sub(" ", t)  # ...which are then stripped; undecoded they read as the word "zwnj"


def message_text(msg):
    texts = []
    for part in msg.walk():
        ct = part.get_content_type()
        if ct not in ("text/plain", "text/html"):
            continue
        payload = part.get_payload(decode=True) or b""
        cs = part.get_content_charset() or "utf-8"
        try:
            t = payload.decode(cs, errors="replace")
        except LookupError:
            t = payload.decode("utf-8", errors="replace")
        texts.append(html_to_text(t) if ct == "text/html" else t)
    text = re.sub(r"https?://\S+", " ", " ".join(texts))
    return re.sub(r"\s+", " ", text).strip()[:BODY_TEXT_MAX]


def body_text(m, uid):
    """Stripped text of the first BODY_FETCH_BYTES of a message (text parts precede attachments)."""
    typ, resp = m.uid("FETCH", uid, f"(BODY.PEEK[]<0.{BODY_FETCH_BYTES}>)")
    raw = next((p[1] for p in resp if isinstance(p, tuple)), b"")
    msg = email.message_from_bytes(raw)
    return message_text(msg), msg


# ---------------------------------------------------------------- language
NON_LATIN = re.compile(r"[Ͱ-ϿЀ-ӿ԰-֏֐-׿؀-ۿऀ-෿"
                       r"฀-๿Ⴀ-ჿሀ-፿぀-ヿ一-鿿가-힯]")
LETTER = re.compile(r"[^\W\d_]")
# English function words that are rare in other Latin-script languages (no is/in/we/at/on/to).
EN_STOP = {"the", "and", "you", "your", "of", "for", "with", "this", "that", "are", "our", "from",
           "have", "will", "can", "what", "here", "about", "their", "there", "when", "which", "would"}
_lang_error_logged = False


def clean_for_lang(text):
    text = INVISIBLE.sub(" ", text)
    text = re.sub(r"[^\w\s̀-ͯऀ-෿'’.,!?-]", " ", text)   # drop symbols/emoji, keep script marks
    return re.sub(r"\s+", " ", text).strip()


def detect_language(subject, body, content_language=""):
    """Return (lang_code, confidence). 'en' with confidence 0.0 means undeterminable."""
    global _lang_error_logged
    if content_language and not content_language.lower().startswith("en"):
        return content_language.lower()[:2], 0.9
    sample = clean_for_lang(f"{subject} {body}")
    letters = len(LETTER.findall(sample))
    nl = len(NON_LATIN.findall(sample))
    if nl > NON_LATIN_MIN and nl > letters * NON_LATIN_RATIO:
        return "non-latin", 0.95
    words = re.findall(r"[A-Za-z’']+", sample)
    if not HAVE_LANGDETECT or len(words) < LANG_MIN_WORDS:
        return "en", 0.0
    head = [w.lower() for w in words[:HEAD_WORDS]]
    stop_ratio = sum(1 for w in head if w in EN_STOP) / len(head)
    if stop_ratio >= EN_STOP_RATIO_SURE:
        return "en", 1.0           # unmistakably English prose
    try:
        langs = detect_langs(" ".join(words[:HEAD_WORDS]))
    except Exception as e:
        if not _lang_error_logged:
            log(f"warning: language detector failed ({type(e).__name__}: {e}); affected mail is treated as English")
            _lang_error_logged = True
        return "en", 0.0
    top = langs[0]
    if top.lang != "en" and top.prob >= SOUP_MIN_CONF and stop_ratio < EN_STOP_RATIO_SURE:
        return top.lang, top.prob  # detector is certain; a few English footer words do not outweigh it
    if stop_ratio >= EN_STOP_RATIO:
        return "en", 1.0
    if stop_ratio == 0 and top.prob < SOUP_MIN_CONF and len(head) < SOUP_MAX_WORDS:
        return "en", 0.0           # short brand-name soup with no sentences: do not guess
    return top.lang, top.prob


# ---------------------------------------------------------------- classification
SUB_CONFIRM = re.compile(r"confirm (your )?(subscription|email)|welcome to|you('re| are) (now )?subscribed"
                         r"|verify your (email|subscription)", re.I)
UNSUB_BODY = re.compile(r"unsubscribe|opt[- ]?out|manage (your )?(email )?preferences|stop receiving", re.I)


def domain(addr):
    return addr.split("@")[-1] if "@" in addr else addr


def is_bulk(h):
    return h["list_unsub"] or h["list_id"] or h["precedence"] in BULK_PRECEDENCE


def looks_marketing(h, body=""):
    """List headers or unsubscribe wording: the fingerprint of bulk marketing mail."""
    return is_bulk(h) or bool(body and UNSUB_BODY.search(body))


def rule_match(rule, h, body=""):
    if "from" in rule and not rx(rule["from"]).search(h["from"]):
        return False
    if "subject" in rule and not rx(rule["subject"]).search(h["subject"]):
        return False
    if rule.get("not_bulk") and is_bulk(h):
        return False
    if rule.get("bulk_only") and not looks_marketing(h, body):
        return False   # support replies / shipping notices from a blocked sender stay
    return True


def classify(h, rules, st, body=""):
    """Return (verdict, reason). Order: learned allow, language, allow rules, block rules, heuristics, keep."""
    if h["from"] in st["learned_allow"]:
        return "allow", "learned"
    lang_cfg = rules["language"]
    if lang_cfg["enabled"]:
        lang, prob = detect_language(h["subject"], body, h.get("content_language", ""))
        allowed = [x.lower() for x in lang_cfg["allowed"]]
        if lang not in allowed and prob >= float(lang_cfg["min_confidence"]):
            return lang_cfg["action"], f"language:{lang}:{prob:.2f}"
    for r in rules["allow"]:
        if rule_match(r, h, body):
            return "allow", f"allow:{r.get('from', '*')}"
    for r in rules["block"]:
        if rule_match(r, h, body):
            return "quarantine", f"block:{r.get('from') or r.get('subject')}"
    hz = rules["heuristics"]
    if hz["enabled"]:
        score, why = 0, []
        if hz["quarantine_if_list_unsubscribe"] and h["list_unsub"]:
            score += hz["weight_list_unsubscribe"]; why.append("list-unsubscribe")
        if hz["quarantine_if_precedence_bulk"] and h["precedence"] in BULK_PRECEDENCE:
            score += hz["weight_precedence"]; why.append("precedence")
        if h["list_id"]:
            score += hz["weight_list_id"]; why.append("list-id")
        if hz["quarantine_if_subscription_confirm"] and SUB_CONFIRM.search(h["subject"]):
            score += hz["weight_subscription_confirm"]; why.append("subscription-confirm")
        if hz["quarantine_if_unsubscribe_link"] and body and UNSUB_BODY.search(body):
            score += hz["unsubscribe_link_weight"]; why.append("unsubscribe-link")
        if score >= hz["min_score"]:
            return "quarantine", "heuristic:" + ",".join(why)
    return "keep", ""


# ---------------------------------------------------------------- unsubscribe
def one_click_unsubscribe(h, timeout=UNSUB_TIMEOUT_S):
    """RFC 8058 one-click only: POST to the https List-Unsubscribe URL when List-Unsubscribe-Post says so.
    Body links are never followed; in a list-bombing they confirm the address is live."""
    if "list-unsubscribe=one-click" not in h["list_unsub_post"].lower():
        return False, "no one-click header"
    urls = re.findall(r"<(https?://[^>]+)>", h["list_unsub_raw"])
    if not urls:
        return False, "no https url in List-Unsubscribe"
    url = urls[0]
    if not url.lower().startswith("https://"):
        return False, "refusing non-https unsubscribe url"
    req = urllib.request.Request(url, data=b"List-Unsubscribe=One-Click", method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded",
                                          "User-Agent": UNSUB_USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return True, f"HTTP {r.status} {url[:80]}"
    except Exception as e:
        return False, f"{type(e).__name__}: {str(e)[:80]}"


# ---------------------------------------------------------------- mail moves
def move_uids(m, uids, dest, what):
    """COPY then flag \\Deleted. Returns True only if the copy was confirmed, so nothing is lost on failure."""
    uidset = b",".join(u.encode() for u in uids)
    typ, resp = m.uid("COPY", uidset, dest)
    if typ != "OK":
        log(f"ERROR: COPY of {len(uids)} {what} to {dest!r} failed ({resp}); leaving them in place")
        return False
    typ, resp = m.uid("STORE", uidset, "+FLAGS", r"(\Deleted)")
    if typ != "OK":
        log(f"ERROR: could not flag {what} deleted after copy ({resp}); duplicates may exist in {dest!r}")
        return False
    return True


def flag_deleted(m, uids):
    typ, resp = m.uid("STORE", b",".join(u.encode() for u in uids), "+FLAGS", r"(\Deleted)")
    if typ != "OK":
        log(f"ERROR: could not flag {len(uids)} messages deleted ({resp})")
    return typ == "OK"


# ---------------------------------------------------------------- commands
def cmd_survey():
    rules = load_rules()
    m = connect()
    hs = fetch_headers(m, rules["settings"]["source_folder"])
    m.logout()
    c = Counter(domain(h["from"]) for h in hs)
    bulk = Counter(domain(h["from"]) for h in hs if is_bulk(h))
    print(f"\n{rules['settings']['source_folder']}: {len(hs)} messages, {sum(bulk.values())} with bulk/list headers\n")
    print(f"{'count':>6} {'bulk':>5}  domain")
    for d, n in c.most_common():
        print(f"{n:>6} {bulk[d]:>5}  {d}")
    atomic_write(SURVEY, json.dumps(hs, indent=1, ensure_ascii=False))


def rules_fingerprint(st):
    return hashlib.sha1((RULES.read_text(encoding="utf-8") + json.dumps(sorted(st["learned_allow"]))).encode("utf-8")).hexdigest()


def prune_state(st, retention_days):
    cutoff = (datetime.now() - timedelta(days=retention_days + QUARANTINE_RECORD_GRACE_DAYS)).isoformat()
    before = len(st["quarantined"])
    st["quarantined"] = {k: v for k, v in st["quarantined"].items() if v.get("when", cutoff) >= cutoff}
    if len(st["quarantined"]) != before:
        log(f"pruned {before - len(st['quarantined'])} quarantine records past retention")


def cmd_scan():
    rules = load_rules()
    s, lang_cfg = rules["settings"], rules["language"]
    dry = s["dry_run"]
    with ScanLock():
        st = load_state()
        prune_state(st, int(s["quarantine_retention_days"]))
        if lang_cfg["enabled"] and not HAVE_LANGDETECT:
            log("warning: language filter is enabled but langdetect is not installed; only non-Latin scripts are detected")
        m = connect()
        src = s["source_folder"]
        qf = resolve_folder(m, s["quarantine_folder"], create=True)
        trash = resolve_folder(m, s["trash_folder"]) if s["delete_to_trash"] else None
        if s["delete_to_trash"] and not trash:
            log(f"warning: trash folder {s['trash_folder']!r} not found; deletions will be permanent")
        hs = fetch_headers(m, src)

        if s["learn_from_restores"]:
            for h in hs:
                rec = st["quarantined"].pop(h["msgid"], None) if h["msgid"] else None
                if rec and rec["from"] not in st["learned_allow"]:
                    st["learned_allow"].append(rec["from"])
                    log(f"learned allow (restored from quarantine): {rec['from']}")

        fp = rules_fingerprint(st)
        if st["rules_fingerprint"] != fp:
            log("rules changed since last scan: re-evaluating every message")
            st["scanned_msgids"], st["rules_fingerprint"] = [], fp
        keep_cache = dict.fromkeys(st["scanned_msgids"])     # ordered set, oldest first
        need_body = lang_cfg["enabled"] or rules["heuristics"]["quarantine_if_unsubscribe_link"]
        moves, deletes = defaultdict(list), defaultdict(list)
        m.select(src, readonly=True)
        todo = [h for h in hs if s["rescan_all"] or not h["msgid"] or h["msgid"] not in keep_cache]
        if need_body and todo:
            print(f"  fetching bodies for {len(todo)} new messages...", flush=True)
        for i, h in enumerate(todo, 1):
            if need_body and i % 50 == 0:
                print(f"  ... {i}/{len(todo)}", flush=True)
            body = ""
            if need_body:
                try:
                    body, _ = body_text(m, h["uid"])
                except Exception as e:
                    log(f"  body fetch failed uid {h['uid']} from {h['from']}: {e}; classifying on headers only")
            verdict, why = classify(h, rules, st, body)
            d = st["seen_domains"].setdefault(domain(h["from"]), {"first": datetime.now().isoformat(), "count": 0})
            d["count"] += 1
            if verdict == "quarantine":
                moves[why].append(h)
            elif verdict == "delete":
                deletes[why].append(h)
            elif h["msgid"]:
                keep_cache[h["msgid"]] = None
        nq, nd = sum(map(len, moves.values())), sum(map(len, deletes.values()))
        log(f"scan: {len(hs)} in {src}, {nq} to quarantine, {nd} to delete, dry_run={dry}")
        tag = "DRY " if dry else ""
        for why, items in moves.items():
            for h in items:
                log(f"  {tag}QUAR {h['from']:<40} {h['subject'][:60]!r} [{why}]")
        for why, items in deletes.items():
            for h in items:
                log(f"  {tag}DEL  {h['from']:<40} {h['subject'][:60]!r} [{why}]")

        if rules["unsubscribe"]["enabled"]:
            done = st["unsubscribed"]
            for h in [x for v in list(moves.values()) + list(deletes.values()) for x in v]:
                if h["from"] in done or not h["list_unsub"]:
                    continue
                if dry:
                    log(f"  DRY UNSUB {h['from']}")
                    continue
                ok, detail = one_click_unsubscribe(h)
                done[h["from"]] = {"ok": ok, "detail": detail, "when": datetime.now().isoformat()}
                log(f"  UNSUB {'ok ' if ok else 'skip'} {h['from']:<40} {detail}")

        moved = trashed = expunged = 0
        if not dry and (nq or nd):
            m.select(src)
            if nq:
                allh = [h for v in moves.values() for h in v]
                if move_uids(m, [h["uid"] for h in allh], qf, "quarantined messages"):
                    moved = len(allh)
                    now = datetime.now().isoformat()
                    for h in allh:
                        if h["msgid"]:
                            st["quarantined"][h["msgid"]] = {"from": h["from"], "when": now}
            if nd:
                uids = [h["uid"] for v in deletes.values() for h in v]
                if trash:
                    if move_uids(m, uids, trash, "deleted messages"):
                        trashed = len(uids)
                elif flag_deleted(m, uids):
                    expunged = len(uids)
            m.expunge()
            log(f"moved {moved} to {qf}" + (f", {trashed} to {trash}" if trash else f", {expunged} permanently deleted"))
        st["scanned_msgids"] = list(keep_cache)[-KEEP_CACHE_MAX:]
        save_state(st)
        write_review(moves, deletes)
        m.logout()


def write_review(moves, deletes):
    """Aggregate flagged mail by sender for the GUI review dialog."""
    agg = {}
    for verdict, groups in (("quarantine", moves), ("delete", deletes)):
        for why, items in groups.items():
            for h in items:
                a = agg.setdefault(h["from"], {"from": h["from"], "domain": domain(h["from"]), "count": 0,
                                               "verdict": verdict, "why": why, "subjects": []})
                a["count"] += 1
                if verdict == "delete":
                    a["verdict"] = "delete"
                if len(a["subjects"]) < 3 and h["subject"] not in a["subjects"]:
                    a["subjects"].append(h["subject"][:90])
    rows = sorted(agg.values(), key=lambda r: (-r["count"], r["domain"]))
    atomic_write(REVIEW, json.dumps({"generated": datetime.now().isoformat(), "rows": rows}, indent=1, ensure_ascii=False))
    log(f"review.json written: {len(rows)} senders")


def apply_review(allow, block):
    """allow -> learned_allow (runs before every other check); block -> bulk_only exact-address block rules.
    An address moved to one list is removed from the other. Returns a summary string."""
    allow = [a.lower().strip() for a in allow if a and a.strip()]
    block = [a.lower().strip() for a in block if a and a.strip()]
    st = load_state()
    st["learned_allow"] = [a for a in st["learned_allow"] if a not in block] + \
                          [a for a in allow if a not in st["learned_allow"]]
    save_state(st)
    rules = load_rules()

    def is_addr_rule(r, addr):
        return r.get("from") == "^" + re.escape(addr) + "$" and "subject" not in r

    existing = [r for r in rules["block"] if not any(is_addr_rule(r, a) for a in allow)]
    for a in block:
        if not any(is_addr_rule(r, a) for r in existing):
            existing.append({"from": "^" + re.escape(a) + "$", "bulk_only": True, "note": "review"})
    rules["block"] = existing
    write_rules(rules)
    return (f"review applied: {len(allow)} allowed senders, {len(block)} blocked senders "
            f"({len(st['learned_allow'])} total learned allows, {len(existing)} block rules)")


def cmd_review_apply():
    data = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    print(apply_review(data.get("allow", []), data.get("block", [])))


def cmd_digest():
    st = load_state()
    last = st["last_digest"]
    new = {d: v for d, v in st["seen_domains"].items() if not last or v["first"] > last}
    print(f"New sender domains since {last or 'start'}:" if new else f"No new sender domains since {last or 'start'}.")
    for d, v in sorted(new.items(), key=lambda x: -x[1]["count"]):
        print(f"  {v['count']:>5}  {d}")
    st["last_digest"] = datetime.now().isoformat()
    save_state(st)


def cmd_purge():
    rules = load_rules()
    s = rules["settings"]
    m = connect()
    qf = resolve_folder(m, s["quarantine_folder"])
    if not qf:
        log(f"purge: quarantine folder {s['quarantine_folder']!r} does not exist; nothing to do")
        m.logout()
        return
    cutoff = (datetime.now() - timedelta(days=int(s["quarantine_retention_days"]))).strftime("%d-%b-%Y")
    m.select(qf)
    typ, data = m.uid("SEARCH", None, f"BEFORE {cutoff}")
    uids = [u.decode() for u in data[0].split()]
    if uids and not s["dry_run"] and flag_deleted(m, uids):
        m.expunge()
    log(f"purge: {len(uids)} quarantined messages older than {cutoff} {'(dry run)' if s['dry_run'] else 'deleted'}")
    m.logout()


def cmd_config_get():
    print(json.dumps(load_rules(), indent=2, ensure_ascii=False))


def cmd_config_set():
    data = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    rules = deep_merge(DEFAULTS, data)
    rules["allow"], rules["block"] = list(rules["allow"] or []), list(rules["block"] or [])
    validate_rules(rules)
    write_rules(rules)
    print("rules.yaml saved")


def cmd_test_connection():
    rules = load_rules()
    s = rules["settings"]
    m = connect()
    typ, data = m.select(s["source_folder"], readonly=True)
    n = int(data[0]) if typ == "OK" and data and data[0] else 0
    qf = resolve_folder(m, s["quarantine_folder"])
    trash = resolve_folder(m, s["trash_folder"])
    m.logout()
    enc = "encrypted" if CREDS.exists() and json.loads(CREDS.read_text(encoding="utf-8")).get("pass_dpapi") else "PLAINTEXT"
    print(f"OK: connected; {s['source_folder']} has {n} messages; quarantine folder "
          f"{'found' if qf else 'will be created on first scan'}; trash folder {'found' if trash else 'NOT found'}; "
          f"langdetect {'available' if HAVE_LANGDETECT else 'MISSING'}; stored password {enc}")


COMMANDS = {
    "survey": cmd_survey, "scan": cmd_scan, "digest": cmd_digest, "purge-quarantine": cmd_purge,
    "test-connection": cmd_test_connection, "config-get": cmd_config_get, "config-set": cmd_config_set,
    "review-apply": cmd_review_apply, "cred-get": cmd_cred_get, "cred-set": cmd_cred_set,
}


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd not in COMMANDS:
        print(__doc__)
        return 1
    try:
        COMMANDS[cmd]()
        return 0
    except LockError as e:
        print(f"SKIPPED: {e}")
        return 3
    except ConfigError as e:
        print(f"FAILED: {e}")
        return 2
    except KeyboardInterrupt:
        print("interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv))
