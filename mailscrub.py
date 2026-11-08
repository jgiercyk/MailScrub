#!/usr/bin/env python3
"""MailScrub: IMAP spam quarantine with allow/block rules, heuristics, and review logging.

Usage:
  python mailscrub.py survey            # read-only: sender-domain histogram of the Inbox
  python mailscrub.py scan              # apply rules; moves mail unless settings.dry_run
  python mailscrub.py digest            # list new sender domains seen since last digest
  python mailscrub.py purge-quarantine  # delete quarantined mail older than retention
Credentials come from env vars MAILSCRUB_HOST, MAILSCRUB_USER, MAILSCRUB_PASS
or from credentials.json in this folder: {"host": "...", "user": "...", "pass": "..."}
"""
import email, email.header, html, imaplib, json, os, re, sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from email.utils import parseaddr
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

HERE = Path(__file__).parent
RULES = HERE / "rules.yaml"
LOG = HERE / "scrub.log"
STATE = HERE / "state.json"


def log(msg):
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def creds():
    cj = HERE / "credentials.json"
    if cj.exists():
        d = json.loads(cj.read_text(encoding="utf-8"))
        return d["host"], d["user"], d["pass"], d.get("port", 993)
    try:
        return (os.environ["MAILSCRUB_HOST"], os.environ["MAILSCRUB_USER"],
                os.environ["MAILSCRUB_PASS"], int(os.environ.get("MAILSCRUB_PORT", 993)))
    except KeyError:
        sys.exit("No credentials: set MAILSCRUB_HOST/USER/PASS or create credentials.json")


def connect():
    host, user, pw, port = creds()
    m = imaplib.IMAP4_SSL(host, port)
    m.login(user, pw)
    return m


def dec(s):
    if not s:
        return ""
    try:
        return str(email.header.make_header(email.header.decode_header(s)))
    except Exception:
        return str(s)


def load_state():
    if STATE.exists():
        return json.loads(STATE.read_text(encoding="utf-8"))
    return {"seen_domains": {}, "learned_allow": [], "quarantined": {}, "last_digest": None}


def save_state(st):
    STATE.write_text(json.dumps(st, indent=2))


HDR_FIELDS = "FROM SUBJECT DATE LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST PRECEDENCE LIST-ID MESSAGE-ID CONTENT-LANGUAGE"

# ---------- language detection ----------
try:
    from langdetect import detect_langs, DetectorFactory
    DetectorFactory.seed = 0
    HAVE_LANGDETECT = True
except ImportError:
    HAVE_LANGDETECT = False

NON_LATIN = re.compile(r"[Ͱ-ϿЀ-ӿ԰-֏֐-׿؀-ۿऀ-෿"
                       r"฀-๿Ⴀ-ჿሀ-፿぀-ヿ一-鿿가-힯]")
LETTER = re.compile(r"[^\W\d_]")


def body_text(m, uid, max_bytes=20000):
    """Fetch and return plain text of a message body (HTML stripped), truncated."""
    typ, resp = m.uid("FETCH", uid, "(BODY.PEEK[])")
    raw = next((p[1] for p in resp if isinstance(p, tuple)), b"")
    msg = email.message_from_bytes(raw)
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
        if ct == "text/html":
            t = re.sub(r"<!--.*?-->", " ", t, flags=re.S)
            t = re.sub(r"<(script|style).*?</\1>", " ", t, flags=re.S | re.I)
            t = re.sub(r"<(script|style)[^>]*>.*", " ", t, flags=re.S | re.I)  # unterminated style block
            t = re.sub(r"<[^>]+>", " ", t)
            t = html.unescape(t)          # &zwnj; &#847; &nbsp; etc. become real characters
            t = INVISIBLE.sub(" ", t)     # ...which the filler-stripper then removes
        texts.append(t)
    text = " ".join(texts)
    text = re.sub(r"https?://\S+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:max_bytes], msg


# Zero-width / filler characters that marketers pad preheaders with. Combining marks used by
# real scripts (e.g. Devanagari vowel signs) are deliberately NOT in this list.
INVISIBLE = re.compile(r"[­͏؜ᅟᅠ឴឵᠎​-‏‪-‮⁠-⁯﻿︀-️ ]+")
# English function words that are rare in other Latin-script languages (no is/in/we/at/on/to...).
EN_STOP = {"the", "and", "you", "your", "of", "for", "with", "this", "that", "are", "our", "from",
           "have", "will", "can", "what", "here", "about", "their", "there", "when", "which", "would"}
HEAD_WORDS = 200   # judge the opening of the message, before any English boilerplate footer


def clean_for_lang(text):
    text = INVISIBLE.sub(" ", text)
    text = re.sub(r"[^\w\s̀-ͯऀ-෿'’.,!?-]", " ", text)  # drop symbols/emoji, keep script marks
    return re.sub(r"\s+", " ", text).strip()


def detect_language(subject, body, content_language=""):
    """Return (lang_code, confidence). 'en' when English or undeterminable."""
    if content_language and not content_language.lower().startswith("en"):
        return content_language.lower()[:2], 0.9
    sample = clean_for_lang(f"{subject} {body}")
    letters = len(LETTER.findall(sample))
    nl = len(NON_LATIN.findall(sample))
    if nl > 10 and nl > letters * 0.2:
        return "non-latin", 0.95
    words = re.findall(r"[A-Za-z’']+", sample)
    if not HAVE_LANGDETECT or len(words) < 12:
        return "en", 0.0
    head = [w.lower() for w in words[:HEAD_WORDS]]
    stop_ratio = sum(1 for w in head if w in EN_STOP) / len(head)
    if stop_ratio >= 0.05:
        return "en", 1.0           # enough English function words up front: it's English
    head_text = " ".join(words[:HEAD_WORDS])
    try:
        langs = detect_langs(head_text)
    except Exception:
        return "en", 0.0
    top = langs[0]
    if stop_ratio == 0 and top.prob < 0.98 and len(head) < 60:
        return "en", 0.0           # short brand-name soup with no sentences: don't guess
    return top.lang, top.prob


# ---------- unsubscribe ----------
def one_click_unsubscribe(h, timeout=10):
    """Honor RFC 8058 one-click unsubscribe only. Returns (ok, detail)."""
    import urllib.request
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
                                          "User-Agent": "MailScrub/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return True, f"HTTP {r.status} {url[:80]}"
    except Exception as e:
        return False, f"{type(e).__name__}: {str(e)[:80]}"


def fetch_headers(m, folder="INBOX", criteria="ALL"):
    m.select(folder, readonly=True)
    typ, data = m.uid("SEARCH", None, criteria)
    uids = data[0].split()
    out = []
    for i in range(0, len(uids), 200):
        chunk = b",".join(uids[i:i + 200])
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
                "date": dec(msg.get("Date")),
                "msgid": (msg.get("Message-ID") or "").strip(),
                "list_unsub": bool(msg.get("List-Unsubscribe")),
                "list_unsub_raw": msg.get("List-Unsubscribe") or "",
                "list_unsub_post": msg.get("List-Unsubscribe-Post") or "",
                "list_id": bool(msg.get("List-Id")),
                "precedence": (msg.get("Precedence") or "").lower(),
                "content_language": msg.get("Content-Language") or "",
            })
    return out


def domain(addr):
    return addr.split("@")[-1] if "@" in addr else addr


def is_bulk(h):
    return h["list_unsub"] or h["list_id"] or h["precedence"] in ("bulk", "list", "junk")


def looks_marketing(h, body=""):
    """List headers or unsubscribe wording: the fingerprint of bulk marketing mail."""
    return is_bulk(h) or bool(body and UNSUB_BODY.search(body))


def rule_match(rule, h, body=""):
    if "from" in rule and not re.search(rule["from"], h["from"], re.I):
        return False
    if "subject" in rule and not re.search(rule["subject"], h["subject"], re.I):
        return False
    if rule.get("not_bulk") and is_bulk(h):
        return False
    if rule.get("bulk_only") and not looks_marketing(h, body):
        return False   # support replies / shipping notices from a blocked sender stay
    return True


SUB_CONFIRM = r"confirm (your )?(subscription|email)|welcome to|you('re| are) (now )?subscribed|verify your (email|subscription)"


UNSUB_BODY = re.compile(r"unsubscribe|opt[- ]?out|manage (your )?(email )?preferences|stop receiving", re.I)


def classify(h, rules, st, body=""):
    if h["from"] in st.get("learned_allow", []):
        return "allow", "learned"
    lang_cfg = rules.get("language", {})
    if lang_cfg.get("enabled") and body is not None:
        lang, prob = detect_language(h["subject"], body, h.get("content_language", ""))
        allowed = [x.lower() for x in lang_cfg.get("allowed", ["en"])]
        if lang not in allowed and prob >= lang_cfg.get("min_confidence", 0.85):
            return lang_cfg.get("action", "delete"), f"language:{lang}:{prob:.2f}"
    for r in rules.get("allow", []):
        if rule_match(r, h, body):
            return "allow", f"allow:{r.get('from', '*')}"
    for r in rules.get("block", []):
        if rule_match(r, h, body):
            return "quarantine", f"block:{r.get('from') or r.get('subject')}"
    hz = rules.get("heuristics", {})
    if hz.get("enabled"):
        score, why = 0, []
        if hz.get("quarantine_if_list_unsubscribe") and h["list_unsub"]:
            score += 1; why.append("list-unsubscribe")
        if hz.get("quarantine_if_precedence_bulk") and h["precedence"] in ("bulk", "list", "junk"):
            score += 1; why.append("precedence")
        if h["list_id"]:
            score += 1; why.append("list-id")
        if hz.get("quarantine_if_subscription_confirm") and re.search(SUB_CONFIRM, h["subject"], re.I):
            score += 2; why.append("subscription-confirm")
        if hz.get("quarantine_if_unsubscribe_link") and body and UNSUB_BODY.search(body):
            score += hz.get("unsubscribe_link_weight", 2); why.append("unsubscribe-link")
        if score >= hz.get("min_score", 2):
            return "quarantine", "heuristic:" + ",".join(why)
    return "keep", ""


def ensure_folder(m, name):
    typ, data = m.list()
    if not any(name.encode() in d for d in data if d):
        m.create(name)
        log(f"created folder {name}")


def cmd_survey():
    m = connect()
    hs = fetch_headers(m)
    c = Counter(domain(h["from"]) for h in hs)
    bulk = Counter(domain(h["from"]) for h in hs if is_bulk(h))
    print(f"\nInbox: {len(hs)} messages, {sum(bulk.values())} with bulk/list headers\n")
    print(f"{'count':>6} {'bulk':>5}  domain")
    for d, n in c.most_common(80):
        print(f"{n:>6} {bulk[d]:>5}  {d}")
    (HERE / "survey.json").write_text(json.dumps(hs, indent=1))
    m.logout()


def cmd_scan():
    rules = yaml.safe_load(RULES.read_text(encoding="utf-8"))
    st = load_state()
    s = rules["settings"]
    dry = s.get("dry_run", True)
    m = connect()
    qf = s["quarantine_folder"]
    ensure_folder(m, qf)
    hs = fetch_headers(m)

    # Learn from restores: a message we quarantined that is back in INBOX means the user rescued it.
    if s.get("learn_from_restores"):
        for h in hs:
            if h["msgid"] and h["msgid"] in st.get("quarantined", {}):
                sender = st["quarantined"][h["msgid"]]
                if sender not in st["learned_allow"]:
                    st["learned_allow"].append(sender)
                    log(f"learned allow (restored from quarantine): {sender}")
                del st["quarantined"][h["msgid"]]

    need_body = rules.get("language", {}).get("enabled") or rules.get("heuristics", {}).get("quarantine_if_unsubscribe_link")
    import hashlib
    fingerprint = hashlib.sha1((RULES.read_text(encoding="utf-8")
                                + json.dumps(sorted(st.get("learned_allow", [])))).encode("utf-8")).hexdigest()
    if st.get("rules_fingerprint") != fingerprint:
        log("rules changed since last scan: re-evaluating every message in the inbox")
        st["scanned_msgids"] = []
        st["rules_fingerprint"] = fingerprint
    already_seen = set(st.get("scanned_msgids", []))
    moves, deletes = defaultdict(list), defaultdict(list)
    m.select("INBOX", readonly=True)
    todo = [h for h in hs if not (h["msgid"] and h["msgid"] in already_seen and not s.get("rescan_all"))]
    if need_body:
        print(f"  fetching bodies for {len(todo)} new messages...", flush=True)
    for i, h in enumerate(todo, 1):
        if need_body and i % 50 == 0:
            print(f"  ... {i}/{len(todo)}", flush=True)
        body = ""
        if need_body:
            try:
                body, _ = body_text(m, h["uid"])
            except Exception as e:
                log(f"  body fetch failed uid {h['uid']}: {e}")
        verdict, why = classify(h, rules, st, body)
        d = domain(h["from"])
        st["seen_domains"].setdefault(d, {"first": datetime.now().isoformat(), "count": 0})
        st["seen_domains"][d]["count"] += 1
        if verdict == "quarantine":
            moves[why].append(h)
        elif verdict == "delete":
            deletes[why].append(h)
        elif h["msgid"]:
            already_seen.add(h["msgid"])
    nq, nd = sum(map(len, moves.values())), sum(map(len, deletes.values()))
    log(f"scan: {len(hs)} in inbox, {nq} to quarantine, {nd} to delete, dry_run={dry}")
    tag = "DRY " if dry else ""
    for why, items in moves.items():
        for h in items:
            log(f"  {tag}QUAR {h['from']:<40} {h['subject'][:60]!r} [{why}]")
    for why, items in deletes.items():
        for h in items:
            log(f"  {tag}DEL  {h['from']:<40} {h['subject'][:60]!r} [{why}]")

    # One-click unsubscribe (RFC 8058 only), once per sender, for mail we are removing.
    u = rules.get("unsubscribe", {})
    if u.get("enabled"):
        done = st.setdefault("unsubscribed", {})
        for h in [x for v in list(moves.values()) + list(deletes.values()) for x in v]:
            if h["from"] in done or not h["list_unsub"]:
                continue
            if dry:
                log(f"  DRY UNSUB {h['from']}")
                continue
            ok, detail = one_click_unsubscribe(h)
            done[h["from"]] = {"ok": ok, "detail": detail, "when": datetime.now().isoformat()}
            log(f"  UNSUB {'ok ' if ok else 'skip'} {h['from']:<40} {detail}")

    if not dry and (nq or nd):
        m.select("INBOX")
        if nq:
            allh = [h for v in moves.values() for h in v]
            uids = b",".join(h["uid"].encode() for h in allh)
            m.uid("COPY", uids, qf)
            m.uid("STORE", uids, "+FLAGS", r"(\Deleted)")
            for h in allh:
                if h["msgid"]:
                    st.setdefault("quarantined", {})[h["msgid"]] = h["from"]
        if nd:
            uids = b",".join(h["uid"].encode() for v in deletes.values() for h in v)
            m.uid("STORE", uids, "+FLAGS", r"(\Deleted)")
        m.expunge()
        log(f"moved {nq} to {qf}, deleted {nd}")
    st["scanned_msgids"] = sorted(already_seen)[-5000:]
    save_state(st)
    write_review(moves, deletes)
    m.logout()


REVIEW = HERE / "review.json"


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
    REVIEW.write_text(json.dumps({"generated": datetime.now().isoformat(), "rows": rows}, indent=1, ensure_ascii=False), encoding="utf-8")
    log(f"review.json written: {len(rows)} senders")


def cmd_review_apply():
    """argv[2] = JSON file {"allow": [addresses], "block": [addresses]}.
    allow -> learned_allow in state.json (checked before language filter)
    block -> exact-address block rules in rules.yaml
    An address moved to one list is removed from the other."""
    data = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    allow = [a.lower().strip() for a in data.get("allow", []) if a.strip()]
    block = [a.lower().strip() for a in data.get("block", []) if a.strip()]
    st = load_state()
    la = [a for a in st.get("learned_allow", []) if a not in block]
    for a in allow:
        if a not in la:
            la.append(a)
    st["learned_allow"] = la
    save_state(st)
    rules = yaml.safe_load(RULES.read_text(encoding="utf-8"))
    existing = rules.get("block") or []
    def is_addr_rule(r, addr):
        return r.get("from") == "^" + re.escape(addr) + "$" and "subject" not in r
    existing = [r for r in existing if not any(is_addr_rule(r, a) for a in allow)]
    for a in block:
        if not any(is_addr_rule(r, a) for r in existing):
            existing.append({"from": "^" + re.escape(a) + "$", "bulk_only": True, "note": "review"})
    rules["block"] = existing
    header = ("# MailScrub rules. Managed by MailScrubGui; hand edits are fine too.\n"
              "# Patterns are Python regexes, case-insensitive.\n\n")
    RULES.write_text(header + yaml.safe_dump(rules, sort_keys=False, allow_unicode=True,
                                             default_flow_style=False, width=1000), encoding="utf-8")
    print(f"review applied: {len(allow)} allowed senders, {len(block)} blocked senders "
          f"({len(st['learned_allow'])} total learned allows, {len(existing)} block rules)")


def cmd_digest():
    st = load_state()
    last = st.get("last_digest")
    new = {d: v for d, v in st["seen_domains"].items() if not last or v["first"] > last}
    print(f"New sender domains since {last or 'start'}:")
    for d, v in sorted(new.items(), key=lambda x: -x[1]["count"]):
        print(f"  {v['count']:>5}  {d}")
    st["last_digest"] = datetime.now().isoformat()
    save_state(st)


def cmd_purge():
    rules = yaml.safe_load(RULES.read_text(encoding="utf-8"))
    s = rules["settings"]
    m = connect()
    cutoff = (datetime.now() - timedelta(days=s["quarantine_retention_days"])).strftime("%d-%b-%Y")
    m.select(s["quarantine_folder"])
    typ, data = m.uid("SEARCH", None, f"BEFORE {cutoff}")
    uids = data[0].split()
    if uids and not s.get("dry_run", True):
        m.uid("STORE", b",".join(uids), "+FLAGS", r"(\Deleted)")
        m.expunge()
    log(f"purge: {len(uids)} quarantined messages older than {cutoff} "
        f"{'(dry run)' if s.get('dry_run', True) else 'deleted'}")
    m.logout()


def cmd_config_get():
    """Print rules.yaml as JSON (for the GUI)."""
    print(json.dumps(yaml.safe_load(RULES.read_text(encoding="utf-8")), indent=2))


def cmd_config_set():
    """Read JSON from the file named in argv[2] and write it to rules.yaml."""
    data = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    header = ("# MailScrub rules. Managed by MailScrubGui; hand edits are fine too.\n"
              "# Patterns are Python regexes, case-insensitive.\n\n")
    RULES.write_text(header + yaml.safe_dump(data, sort_keys=False, allow_unicode=True,
                                             default_flow_style=False, width=1000), encoding="utf-8")
    print("rules.yaml saved")


def cmd_test_connection():
    try:
        m = connect()
        typ, data = m.select("INBOX", readonly=True)
        n = int(data[0]) if data and data[0] else 0
        m.logout()
        print(f"OK: connected, INBOX has {n} messages")
    except Exception as e:
        print(f"FAILED: {type(e).__name__}: {e}")
        sys.exit(1)


if __name__ == "__main__":
    cmds = {"survey": cmd_survey, "scan": cmd_scan, "digest": cmd_digest, "purge-quarantine": cmd_purge,
            "config-get": cmd_config_get, "config-set": cmd_config_set, "test-connection": cmd_test_connection,
            "review-apply": cmd_review_apply}
    cmds.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: print(__doc__))()
