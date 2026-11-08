"""MailScrub engine tests. Run from C:\\mailscrub:  python -X utf8 -m pytest -q

No network: IMAP is replaced by a tiny fake that serves recorded bytes. Each test gets a
fresh data folder through set_home(), so rules.yaml / state.json in the project are untouched.
"""
import json
import os
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mailscrub as ms  # noqa: E402


# ------------------------------------------------------------------ fixtures
@pytest.fixture
def home(tmp_path):
    ms.set_home(tmp_path)
    ms.write_rules(ms.deep_merge(ms.DEFAULTS, {"settings": {"dry_run": True}}))
    yield tmp_path
    ms.set_home(Path(ms.__file__).parent)


def H(frm, subj, unsub=False, list_id=False, prec="", post="", content_language=""):
    return {"uid": "1", "from": frm, "subject": subj, "msgid": f"<{frm}-{abs(hash(subj))}>",
            "list_unsub": unsub, "list_unsub_raw": "<https://x.example/u>" if unsub else "",
            "list_unsub_post": post, "list_id": list_id, "precedence": prec, "content_language": content_language}


class FakeImap:
    """Serves one raw message for any UID."""
    def __init__(self, raw: bytes):
        self.raw = raw

    def uid(self, cmd, *args):
        assert cmd == "FETCH"
        return "OK", [(b"1 (UID 1 BODY[]<0> {%d}" % len(self.raw), self.raw), b")"]


def rules(**over):
    r = ms.deep_merge(ms.DEFAULTS, over)
    r["allow"], r["block"] = list(r["allow"]), list(r["block"])
    ms.validate_rules(r)
    return r


ST = {"learned_allow": [], "quarantined": {}, "seen_domains": {}, "scanned_msgids": [], "unsubscribed": {}}


# ------------------------------------------------------------------ language detection
@pytest.mark.parametrize("subject, body, want", [
    ("Your order shipped", "Thanks for your order. We will let you know when it arrives at your door and what to do.", "en"),
    ("Herzlichen Glueckwunsch", "Sie haben heute einen Gutschein gewonnen. Klicken Sie hier um ihn jetzt einzuloesen und sparen Sie bei Ihrem Einkauf.", "de"),
    ("सीरिया को आतंकवाद", "अमेरिका ने नेपाल में बाढ़ पीड़ितों के प्रति संवेदना व्यक्त की है और सहायता की पेशकश की है", "non-latin"),
    ("Поздравляем", "Поздравляем, вы выиграли приз. Нажмите здесь чтобы получить ваш приз сегодня", "non-latin"),
    ("Turner Labor Day Sale", "View in Browser Turner Motorsport ECS Tuning Dinan LIQUI MOLY BILSTEIN APEX AWE EBC CSF Brembo Bosch URO Rein Elring", "en"),
])
def test_detect_language(subject, body, want):
    lang, prob = ms.detect_language(subject, body)
    assert lang == want, (lang, prob)


def test_english_footer_does_not_mask_dutch_body():
    body = ("Dagelijks nieuws over e-commerce. E-commerce nieuws dat je niet mag missen. Nieuwste artikelen op "
            "Ecommerce Bridge. Meta sluit de desktopapp van Facebook Messenger uit. Meta heeft de native app "
            "voor Windows en macOS stopgezet, gebruikers moeten nu de webversie gebruiken. ") * 3
    body += " You are receiving this because you subscribed. Unsubscribe from this list here. Manage your preferences."
    lang, prob = ms.detect_language("Dagelijks nieuws", body)
    assert lang == "nl" and prob > 0.85


def test_zwnj_entities_are_decoded_not_read_as_polish():
    """Regression: undecoded &zwnj; filler made langdetect return 'pl' at 1.00 for English utility mail."""
    filler = " &zwnj;" * 400 + " &#847;&zwnj;" * 200
    html = ("<html><body><p>We need to replace the gas meter at your home. The natural gas meter at your home is due "
            f"for a meter replacement. Please visit our online appointment portal to schedule.</p>{filler}</body></html>")
    raw = (b"From: gas@example.com\r\nSubject: We need to replace the gas meter\r\n"
           b"Content-Type: text/html; charset=utf-8\r\n\r\n" + html.encode())
    text, _ = ms.body_text(FakeImap(raw), "1")
    assert "zwnj" not in text.lower()
    lang, prob = ms.detect_language("We need to replace the gas meter", text)
    assert lang == "en"


def test_html_comments_and_unterminated_style_are_stripped():
    html = "<!-- start reset css --><style>body{color:red} td,p{line-height:1}<div>Visible text that is in English and should remain here for the reader.</div>"
    text = ms.html_to_text(html)
    assert "line-height" not in text and "Visible text" in text


# ------------------------------------------------------------------ classification order
def test_learned_allow_beats_language_filter():
    st = dict(ST, learned_allow=["amigo@example.es"])
    v, why = ms.classify(H("amigo@example.es", "Hola amigo"), rules(), st,
                         "Hola amigo, como estas hoy? Espero que todo este bien contigo y con tu familia en casa.")
    assert (v, why) == ("allow", "learned")


def test_language_delete_before_allow_rules():
    r = rules(allow=[{"from": "example\\.de$"}])
    v, why = ms.classify(H("shop@example.de", "Angebot"), r, dict(ST),
                         "Sie haben heute einen Gutschein gewonnen. Klicken Sie hier um ihn jetzt einzuloesen und sparen Sie.")
    assert v == "delete" and why.startswith("language:de")


def test_allow_rule_rescues_receipt_with_unsubscribe_footer():
    r = rules(allow=[{"from": "amazon\\.com$", "subject": "order|shipped"}])
    v, _ = ms.classify(H("ship@amazon.com", "Your order has shipped", unsub=True), r, dict(ST), "Thanks. Unsubscribe here.")
    assert v == "allow"
    v, why = ms.classify(H("deals@amazon.com", "Deals of the day", unsub=True), r, dict(ST), "Shop now. Unsubscribe here.")
    assert v == "quarantine" and "unsubscribe-link" in why


def test_bulk_only_block_lets_support_reply_through():
    r = rules(block=[{"from": "^hello@pinter\\.com$", "bulk_only": True}])
    v, _ = ms.classify(H("hello@pinter.com", "Re: my tap is leaking"), r, dict(ST), "Hi Jim, sorry about that. Try this fix.")
    assert v == "keep"
    v, why = ms.classify(H("hello@pinter.com", "How to brew Deep Shade Coffee", unsub=True), r, dict(ST), "Brew guide. Unsubscribe.")
    assert v == "quarantine" and why.startswith("block:")


def test_heuristic_weights_from_config():
    r = rules(heuristics={"unsubscribe_link_weight": 1, "min_score": 2})
    v, _ = ms.classify(H("x@shop.example", "Sale"), r, dict(ST), "Big sale. Opt out below.")
    assert v == "keep"           # one point only
    v, _ = ms.classify(H("x@shop.example", "Sale", unsub=True), r, dict(ST), "Big sale. Opt out below.")
    assert v == "quarantine"     # list-unsubscribe + wording = 2


def test_subscription_confirm_subject():
    v, why = ms.classify(H("noreply@list.example", "Please confirm your subscription"), rules(), dict(ST), "Click to confirm.")
    assert v == "quarantine" and "subscription-confirm" in why


# ------------------------------------------------------------------ rules loading and validation
def test_defaults_merged_and_validated(home):
    (home / "rules.yaml").write_text("allow:\n- from: amazon\\.com$\n", encoding="utf-8")
    r = ms.load_rules()
    assert r["settings"]["quarantine_folder"] == "Quarantine"
    assert r["heuristics"]["min_score"] == 2 and r["block"] == []


@pytest.mark.parametrize("yaml_text, needle", [
    ("block:\n- from: '(unclosed'\n", "invalid regex"),
    ("block:\n- note: nothing\n", "must have a 'from' and/or 'subject'"),
    ("language:\n  action: nuke\n", "language.action"),
    ("settings:\n  quarantine_retention_days: 0\n", "quarantine_retention_days"),
    ("settings:\n  source_folder: Q\n  quarantine_folder: Q\n", "must differ"),
    ("- just a list\n", "mapping"),
])
def test_invalid_rules_fail_clearly(home, yaml_text, needle):
    (home / "rules.yaml").write_text(yaml_text, encoding="utf-8")
    with pytest.raises(ms.ConfigError) as e:
        ms.load_rules()
    assert needle in str(e.value)


def test_missing_rules_file(home):
    (home / "rules.yaml").unlink()
    with pytest.raises(ms.ConfigError):
        ms.load_rules()


def test_rules_round_trip_preserves_bulk_only_and_note(home):
    r = rules(block=[{"from": "^a@b\\.c$", "bulk_only": True, "note": "review"}])
    ms.write_rules(r)
    again = ms.load_rules()
    assert again["block"][0] == {"from": "^a@b\\.c$", "bulk_only": True, "note": "review"}


# ------------------------------------------------------------------ state, atomic writes, lock
def test_state_round_trip_unicode_and_backup(home):
    st = ms.fresh_state()
    st["learned_allow"].append("jörg@exämple.de")
    ms.save_state(st)
    ms.save_state(st)
    assert (home / "state.json.bak").exists()
    assert ms.load_state()["learned_allow"] == ["jörg@exämple.de"]
    assert not list(home.glob("*.tmp"))


def test_corrupt_state_fails_clearly(home):
    (home / "state.json").write_text("{not json", encoding="utf-8")
    with pytest.raises(ms.ConfigError) as e:
        ms.load_state()
    assert "state.json" in str(e.value)


def test_state_migration_and_prune(home):
    old = ms.fresh_state()
    old["quarantined"] = {"<a>": "spam@x.example"}          # legacy string form
    (home / "state.json").write_text(json.dumps(old), encoding="utf-8")
    st = ms.load_state()
    assert st["quarantined"]["<a>"]["from"] == "spam@x.example"
    st["quarantined"]["<old>"] = {"from": "z@x", "when": "2000-01-01T00:00:00"}
    ms.prune_state(st, 14)
    assert "<old>" not in st["quarantined"] and "<a>" in st["quarantined"]


def test_scan_lock_blocks_second_run_and_overrides_stale(home):
    with ms.ScanLock():
        with pytest.raises(ms.LockError):
            with ms.ScanLock():
                pass
    assert not (home / "scan.lock").exists()
    (home / "scan.lock").write_text("1 dead", encoding="utf-8")
    os.utime(home / "scan.lock", (time.time() - ms.LOCK_STALE_S - 5,) * 2)
    with ms.ScanLock():
        pass                                                 # stale lock taken over, no error


# ------------------------------------------------------------------ review apply
def test_apply_review_moves_between_lists(home):
    msg = ms.apply_review(allow=["Keep@Me.com"], block=["junk@spam.example", "Keep@Me.com".lower()])
    st = ms.load_state(); r = ms.load_rules()
    assert "keep@me.com" in st["learned_allow"]
    blocked = [b["from"] for b in r["block"]]
    assert "^junk@spam\\.example$" in blocked and all(b.get("bulk_only") for b in r["block"])
    # second pass: user changes mind, junk becomes keep
    ms.apply_review(allow=["junk@spam.example"], block=[])
    st = ms.load_state(); r = ms.load_rules()
    assert "junk@spam.example" in st["learned_allow"] and not any("junk" in b["from"] for b in r["block"])
    assert "review applied" in msg


# ------------------------------------------------------------------ credentials
@pytest.mark.skipif(sys.platform != "win32", reason="DPAPI is Windows-only")
def test_dpapi_round_trip():
    assert ms.dpapi_unprotect(ms.dpapi_protect("pässwörd 123")) == "pässwörd 123"


@pytest.mark.skipif(sys.platform != "win32", reason="DPAPI is Windows-only")
def test_cred_set_encrypts_and_deletes_input(home, monkeypatch, capsys):
    inp = home / "in.json"
    inp.write_text(json.dumps({"host": "imap.example", "port": 993, "user": "u@example", "pass": "pw"}), encoding="utf-8")
    monkeypatch.setattr(sys, "argv", ["mailscrub.py", "cred-set", str(inp)])
    ms.cmd_cred_set()
    assert not inp.exists()
    saved = json.loads((home / "credentials.json").read_text(encoding="utf-8"))
    assert "pass" not in saved and saved["pass_dpapi"]
    assert ms.creds() == ("imap.example", "u@example", "pw", 993)


def test_env_creds_win(home, monkeypatch):
    monkeypatch.setenv("MAILSCRUB_HOST", "h"); monkeypatch.setenv("MAILSCRUB_USER", "u"); monkeypatch.setenv("MAILSCRUB_PASS", "p")
    assert ms.creds() == ("h", "u", "p", ms.IMAP_PORT_DEFAULT)


def test_missing_creds_is_config_error(home, monkeypatch):
    monkeypatch.delenv("MAILSCRUB_HOST", raising=False)
    with pytest.raises(ms.ConfigError):
        ms.creds()


# ------------------------------------------------------------------ unsubscribe safety
def test_unsubscribe_requires_one_click_header_and_https():
    assert ms.one_click_unsubscribe(H("a@b", "s", unsub=True))[0] is False
    h = H("a@b", "s", unsub=True, post="List-Unsubscribe=One-Click"); h["list_unsub_raw"] = "<http://insecure.example/u>"
    ok, why = ms.one_click_unsubscribe(h)
    assert ok is False and "non-https" in why


# ------------------------------------------------------------------ CLI
def test_unknown_command_prints_usage(capsys):
    assert ms.main(["mailscrub.py", "bogus"]) == 1
    assert "Usage" in capsys.readouterr().out


def test_config_error_exit_code(home, capsys):
    (home / "rules.yaml").write_text("language:\n  action: nuke\n", encoding="utf-8")
    assert ms.main(["mailscrub.py", "config-get"]) == 2
    assert "FAILED" in capsys.readouterr().out
