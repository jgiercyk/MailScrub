# MailScrub

IMAP spam-quarantine system for Jim's mailbox at DomainNameSanity (cPanel hosting).
Built 2026-11-07 in response to a list-bombing attack that exhausted the webmail filter cap.
Python engine + PowerShell WinForms GUI + two Windows scheduled tasks. Went live the same day;
Inbox reached zero for the first time in decades.

## Layout

| Path | Role |
|---|---|
| `mailscrub.py` | Engine and CLI. All mail logic lives here. |
| `MailScrubGui.ps1` | WinForms front end (Connection, Rules, Filters, Settings, Run, Docs tabs + Review dialog). Talks to the engine only through its CLI. |
| `MailScrub.cmd` | Double-click launcher (`pwsh -STA -WindowStyle Hidden -File MailScrubGui.ps1`). Desktop shortcut points here. |
| `MailScrub.ico` | App icon, generated with Pillow. |
| `Place-DesktopIcon.ps1` | Moves the desktop icon to a screen corner via Win32 ListView messages. |
| `rules.yaml` | All user configuration. Managed by the GUI; hand edits are fine. |
| `state.json` | Learned allows, keep cache, seen domains, unsubscribe history, quarantined msgids, rules fingerprint. |
| `credentials.json` | IMAP host/port/user/pass. **Secret. Never commit, never print.** ACL-restricted to Jim's account. |
| `scrub.log` | Every decision with its reason. Append-only, no rotation yet. |
| `review.json` | Senders flagged by the last scan, consumed by the Review dialog. |
| `survey.json` | Raw header dump from the last `survey`. |

## Running

```
python -X utf8 mailscrub.py survey             # read-only sender-domain histogram
python -X utf8 mailscrub.py scan               # apply rules (honours settings.dry_run)
python -X utf8 mailscrub.py digest             # new sender domains since last digest
python -X utf8 mailscrub.py purge-quarantine   # delete quarantined mail past retention
python -X utf8 mailscrub.py test-connection
python -X utf8 mailscrub.py config-get         # rules.yaml as JSON (GUI bridge)
python -X utf8 mailscrub.py config-set <json>  # JSON file -> rules.yaml
python -X utf8 mailscrub.py review-apply <json>  # {"allow":[addrs],"block":[addrs]}
pwsh -NoProfile -STA -File MailScrubGui.ps1    # GUI
```

Always run Python with `-X utf8` (subjects contain every script on earth; the console is cp1252).
Do **not** use `-I`: langdetect and PyYAML are in the user site-packages.
Dependencies: Python 3.14, `pyyaml`, `langdetect`, `pillow` (icon only). PowerShell 7 for the GUI
(5.1 also works). Scheduled tasks: **MailScrub Scan** every 15 min, **MailScrub Purge** daily 03:00,
both run `C:\Python314\python.exe` against this folder. Installed/updated from the GUI Settings tab.

## How classification works

Evaluation order per message, first match wins:

1. `state.learned_allow` (exact address) → ALLOW. Runs before the language filter on purpose.
2. Language filter → DELETE (or quarantine, per `language.action`) if confidently not in `language.allowed`.
3. `rules.allow` → ALLOW. `from`/`subject` are case-insensitive Python regexes; both must match when both given. `not_bulk: true` = only when no list headers.
4. `rules.block` → QUARANTINE. `bulk_only: true` = fire only when the message has list headers or unsubscribe wording (`looks_marketing`). Review-dialog blocks are always `bulk_only`, so support replies and shipping notices from a blocked address survive.
5. Heuristics score (List-Unsubscribe, Precedence bulk, List-Id, subscription-confirm subject, unsubscribe wording in body) → QUARANTINE at `min_score`.
6. Otherwise KEEP, and the msgid goes into the keep cache.

Keep cache (`state.scanned_msgids`) is cleared automatically when `rules.yaml` or `learned_allow`
changes (sha1 fingerprint in state). Without this, rule changes never reach mail already judged keep.

Unsubscribe: RFC 8058 one-click only (POST to the https URL in List-Unsubscribe when
List-Unsubscribe-Post is present). Body links are **never** followed. Once per sender; results in `state.unsubscribed`.

Learn-from-restore: a message we quarantined that reappears in INBOX adds its sender to `learned_allow`.

## Language detection: hard-won rules

- HTML → text must `html.unescape()` **after** tag stripping and then strip zero-width filler
  (`INVISIBLE` regex). Marketers pad preheaders with hundreds of `&zwnj;`/`&#847;`; undecoded,
  langdetect reads the literal word "zwnj" and returns Polish at 1.00 confidence. This nearly deleted
  a gas-meter notice, a utility bill alert, a Wix contact form and an order confirmation.
- Strip HTML comments and unterminated `<style>` blocks; CSS leaks otherwise.
- Do not strip combining marks: Devanagari vowel signs are combining marks.
- `NON_LATIN` covers Greek, Cyrillic, Armenian, Hebrew, Arabic, all Indic (U+0900–0DFF), Thai,
  Georgian, Ethiopic, CJK, Hangul. Compared against letter count, not string length.
- English stopword test uses only words rare in other Latin languages (no is/in/we/at/on) and only
  the first 200 words, so English unsubscribe footers cannot mask a Dutch or Romanian body.
- Short brand-name soup with zero stopwords and <0.98 confidence → treat as English, don't guess.

## Conventions and pitfalls

- The GUI must round-trip **every** key in `rules.yaml`. Grids only save the columns they know;
  a key the grid lacks is silently dropped on the next save (this is how `note`/`bulk_only` were lost once).
- `$Args` is a PowerShell automatic variable. Never name a parameter `$Args`.
- WinForms `Columns.AddRange` rejects PowerShell arrays; add columns one at a time.
- `ConvertFrom-Json` turns ISO timestamps into `[datetime]`; cast before string methods.
- Long engine runs go through the background runner (temp file + UI timer), never synchronously
  on the UI thread. The first scan downloads every body and takes about a minute per 600 messages.
- Shell heredocs in this environment mangle backslashes and `\n` escapes inside Python source.
  Patch `.py`/`.ps1` files with the Edit/Write tools, not `python - <<EOF` or `sed`.
- Headless GUI tests: copy the script, replace `[void]$form.ShowDialog()` with a timer that
  inspects controls and closes the form, run with `pwsh -STA -File`. Restore `state.json`/`rules.yaml`
  after any test that calls Save.
- Verify against the live mailbox read-only (`m.select(..., readonly=True)`, `BODY.PEEK`) before any
  change that affects verdicts; the user's real mail is the only realistic test corpus.
- Safety margin preference: quarantine (reversible, 14-day retention) over delete whenever cheap.
  Foreign-language delete is a deliberate user choice; everything else is quarantine.

## State of the mailbox (2026-11-07 night)

924 messages in Inbox at start. Live runs moved 530 to Quarantine and deleted 61 foreign-language
messages. 160 one-click unsubscribes succeeded (a "Subscriber Deleted" confirmation from the State
Department feed came back). Jim then emptied the remaining legitimate mail himself. Trash held 1,934,
Spam 1,121 (server-side SpamAssassin, untouched by MailScrub).

## Open ideas (not started)

Git repo with `.gitignore` for secrets/state/logs; log rotation; split engine into modules; pytest
suite with recorded header/body fixtures; multi-account support; sender reputation learned from
review decisions; cPanel server-side filter sync for the worst offenders; daily digest email or
tray notification; web dashboard.
