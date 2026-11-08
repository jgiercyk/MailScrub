# MailScrub

IMAP spam-quarantine system for Jim's mailbox at DomainNameSanity (cPanel hosting).
Built 2026-11-07 in response to a list-bombing attack that exhausted the webmail filter cap.
Python engine + PowerShell WinForms GUI + two Windows scheduled tasks. Went live the same day;
Inbox reached zero for the first time in decades. Brought into conformance with `boilerplate.md`
the same night (git history starts at that checkpoint).

## Standing Development Rules

Also follow the shared project boilerplate in `boilerplate.md`. When task-specific instructions
conflict with it, ask for clarification unless the task-specific instruction is clearly more
restrictive and safer. Report completed work in the boilerplate's §20 session format.

## Layout

| Path | Role |
|---|---|
| `mailscrub.py` | Engine and CLI. All mail logic lives here. Single file by design; split only when a section exceeds a screen or two. |
| `MailScrubGui.ps1` | WinForms front end (Connection, Rules, Filters, Settings, Run, Docs tabs + Review dialog). Talks to the engine only through its CLI, never touches rules/state files directly except to read review.json and learned_allow for display. |
| `MailScrub.cmd` | Double-click launcher. The desktop shortcut points at the GUI script with `-STA -WindowStyle Hidden`. |
| `MailScrub.ico` | App icon, generated with Pillow. |
| `Place-DesktopIcon.ps1` | Moves the desktop icon to a screen corner via Win32 ListView messages. One-off utility. |
| `tests/test_engine.py` | pytest suite, no network. `python -X utf8 -m pytest -q` from the project root. |
| `rules.yaml` | All user configuration. Missing keys take `DEFAULTS` in the engine. Managed by the GUI; hand edits are fine. |
| `state.json` (+ `.bak`) | Learned allows, keep cache, seen domains, unsubscribe history, quarantined msgids, rules fingerprint. `.bak` is the previous version. |
| `credentials.json` | IMAP host/port/user and `pass_dpapi`, the password encrypted with Windows DPAPI for Jim's account. **Secret. Never commit, never print.** Also ACL-restricted. |
| `scan.lock` | Present only while a scan runs. Stale after 40 min and overridden. |
| `scrub.log` (+ `.log.1`..`.5`) | Every decision with its reason. Rotates at 2 MB, five backups. |
| `review.json` | Senders flagged by the last scan, consumed by the Review dialog. |
| `survey.json` | Raw header dump from the last `survey`. |
| `boilerplate.md` | Standing development rules (see above). |

## Running

```
python -X utf8 mailscrub.py survey             # read-only sender-domain histogram
python -X utf8 mailscrub.py scan               # apply rules (honours settings.dry_run); exit 3 if another scan holds the lock
python -X utf8 mailscrub.py digest             # new sender domains since last digest
python -X utf8 mailscrub.py purge-quarantine   # delete quarantined mail past retention
python -X utf8 mailscrub.py test-connection    # folders, langdetect, password encryption status
python -X utf8 mailscrub.py config-get         # rules.yaml with defaults applied, as JSON (GUI bridge)
python -X utf8 mailscrub.py config-set <json>  # JSON file -> rules.yaml (validated)
python -X utf8 mailscrub.py review-apply <json>  # {"allow":[addrs],"block":[addrs]}
python -X utf8 mailscrub.py cred-get           # host/port/user, never the password
python -X utf8 mailscrub.py cred-set <json>    # {"host","port","user","pass"}; input file is deleted; empty pass keeps the stored one
pwsh -NoProfile -STA -File MailScrubGui.ps1    # GUI
python -X utf8 -m pytest -q                    # tests
```

Exit codes: 0 ok, 1 usage, 2 configuration error (message starts `FAILED:`), 3 lock held (`SKIPPED:`).
Always run Python with `-X utf8` (subjects contain every script on earth; the console is cp1252).
Do **not** use `-I`: langdetect, PyYAML and pytest are in the user site-packages.
`MAILSCRUB_HOME` points the engine at another data folder (tests use `set_home()`).
Dependencies: Python 3.14, `pyyaml`, `langdetect`, `pytest` (tests), `pillow` (icon only). PowerShell 7 for the GUI.
Scheduled tasks **MailScrub Scan** (every 15 min) and **MailScrub Purge** (daily 03:00) run
`C:\Python314\python.exe` against this folder; install/update from the GUI Settings tab.

## How classification works

Evaluation order per message, first match wins (`classify()`):

1. `state.learned_allow` (exact address) → ALLOW. Runs before the language filter on purpose.
2. Language filter → `language.action` (delete = move to Trash when `settings.delete_to_trash` and a Trash folder exists) if confidently not in `language.allowed`.
3. `rules.allow` → ALLOW. `from`/`subject` are case-insensitive Python regexes; both must match when both given. `not_bulk: true` = only when no list headers.
4. `rules.block` → QUARANTINE. `bulk_only: true` = fire only when the message has list headers or unsubscribe wording (`looks_marketing`). Review-dialog blocks are always `bulk_only`, so support replies and shipping notices from a blocked address survive.
5. Heuristics: weighted signals (List-Unsubscribe, Precedence bulk, List-Id, subscription-confirm subject, unsubscribe wording in body), all weights in `rules.heuristics` → QUARANTINE at `min_score`.
6. Otherwise KEEP; the msgid goes into the keep cache (`state.scanned_msgids`, oldest evicted at 5000).

The keep cache is cleared automatically when `rules.yaml` or `learned_allow` changes (sha1 fingerprint
in state). Without this, rule changes never reach mail already judged keep.

Mail moves: `move_uids()` COPYs first and flags `\Deleted` only after the server confirms the copy.
A failed copy leaves the mail in place and logs `ERROR:`. Nothing is expunged that was not copied.

Unsubscribe: RFC 8058 one-click only (POST to the https URL in List-Unsubscribe when
List-Unsubscribe-Post is present). Body links are **never** followed. Once per sender; results in `state.unsubscribed`.

Learn-from-restore: a message we quarantined that reappears in the source folder adds its sender to `learned_allow`.

## Language detection: hard-won rules

- HTML → text must `html.unescape()` **after** tag stripping and then strip zero-width filler
  (`INVISIBLE` regex). Marketers pad preheaders with hundreds of `&zwnj;`/`&#847;`; undecoded,
  langdetect reads the literal word "zwnj" and returns Polish at 1.00 confidence. This nearly deleted
  a gas-meter notice, a utility bill alert, a Wix contact form and an order confirmation. Regression test exists.
- Strip HTML comments; an unterminated `<style>` block is dropped only up to the next tag.
- Do not strip combining marks: Devanagari vowel signs are combining marks.
- `NON_LATIN` covers Greek, Cyrillic, Armenian, Hebrew, Arabic, all Indic, Thai, Georgian, Ethiopic,
  CJK, Hangul. Compared against letter count, not string length.
- English stopword test uses only words rare in other Latin languages (no is/in/we/at/on) over the
  first 200 words. A confident (≥0.98) non-English detector verdict beats a weak stopword count
  (<0.10); a strong count (≥0.10) beats the detector. Short brand-name soup with no stopwords is not guessed.
- Body fetch is a partial `BODY.PEEK[]<0.65536>`: text parts precede attachments, so this is enough and
  avoids downloading attachments.

## Conventions and pitfalls

- The GUI must round-trip **every** key in `rules.yaml`. Grids only save the columns they know, and
  `Collect-Config` must list every settings key; a key the GUI lacks reverts to the engine default on save.
  Test: load, Save, compare `deep_merge(DEFAULTS, before)` with `after`.
- Never save silently. Scan/Purge/Install call `Confirm-SavedBeforeRun`, which asks when `Test-Dirty`.
- `$Args` is a PowerShell automatic variable. Never name a parameter `$Args`.
- WinForms `Columns.AddRange` rejects PowerShell arrays; add columns one at a time.
- `ConvertFrom-Json` turns ISO timestamps into `[datetime]`; cast before string methods.
- `Invoke-Engine` reads stderr asynchronously; reading both pipes sequentially can deadlock.
- Long engine runs go through the background runner (temp file + UI timer), never synchronously
  on the UI thread. Temp files use GUID names and are deleted when the run ends.
- Shell heredocs in this environment mangle backslashes and `\n` escapes inside Python source.
  Patch `.py`/`.ps1` files with the Edit/Write tools, not `python - <<EOF` or `sed`.
- Headless GUI tests: copy the script, replace `$form.Add_Shown({ Load-All })` with a probe that
  inspects controls and closes the form, run with `pwsh -STA -File`. Revert any edits before closing or
  the FormClosing prompt blocks. Restore `state.json`/`rules.yaml` after any test that calls Save.
- Verify against the live mailbox read-only (`m.select(..., readonly=True)`, `BODY.PEEK`) before any
  change that affects verdicts; the user's real mail is the only realistic test corpus.
- Safety margin preference: quarantine (reversible, 14-day retention) over delete whenever cheap.
  "delete" verdicts go to Trash, not expunge, unless no Trash folder exists.
- All state/rules/review writes go through `atomic_write()`.

## State of the mailbox (2026-11-07 night)

924 messages in Inbox at start. Live runs moved 530 to Quarantine and deleted 61 foreign-language
messages. 160 one-click unsubscribes succeeded (a "Subscriber Deleted" confirmation from the State
Department feed came back). Jim then emptied the remaining legitimate mail himself. Trash held 1,934,
Spam 1,121 (server-side SpamAssassin, untouched by MailScrub).

## Known limitations

- `seen_domains` and `unsubscribed` in state.json grow without bound (hundreds of entries per year; harmless for now).
- One mailbox per data folder. Multi-account would mean one folder per account and `MAILSCRUB_HOME`.
- The GUI reads `state.json` directly for the learned-allow checkmarks in Review (read-only).
- The scheduled task's interval can drift from `settings.scan_every_minutes`; the Settings panel shows the live task state and labels the box as the Install default.

## Open ideas (not started)

Sender reputation learned from review decisions; cPanel server-side filter sync for the worst
offenders; daily digest email or tray notification; web dashboard; multi-account.
