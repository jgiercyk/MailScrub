# Boilerplate Development Instructions

This file is intended to be referenced by `CLAUDE.md` or equivalent project instructions. It defines standing development expectations for cleanup, maintainability, safety, token efficiency, threading, security, and testing.

## How to Use This File

Before making code changes:

1. Read the active task instructions.
2. Read this boilerplate.
3. Identify which sections apply to the current task.
4. Work narrowly unless explicitly asked for a broader refactor.
5. Preserve the last known good state before making risky changes.
6. Provide a summary, test results, known limitations, and rollback notes.

Suggested pointer from `CLAUDE.md`:

```markdown
## Standing Development Rules

Also follow the shared project boilerplate in:

`boilerplate.md`

When task-specific instructions conflict with `boilerplate.md`, ask for clarification unless the task-specific instruction is clearly more restrictive and safer.
```

---

# 1. Core Operating Principles

## 1.1 Preserve Working Behavior

- Do not break known-good behavior while improving adjacent code.
- Treat current working behavior as a contract unless the task explicitly changes it.
- Create a restore/checkpoint before risky cleanup or refactoring.
- If a change destabilizes the app, stop and roll back before adding more changes.

## 1.2 Make State Honest

The UI, internal registry, logs, and actual runtime behavior must agree.

Never show something as:

- active if it is not active,
- disabled if it is still processing,
- saved if it is only session-only,
- live if it is only staged,
- successful if the operation was not confirmed.

## 1.3 Prefer Simple, Explicit Systems

- Use exact values and exact state transitions.
- Avoid magic behavior.
- Avoid hidden defaults that override user choices.
- Avoid broad catch-all logic unless it is clearly labeled and intentional.
- Prefer small deterministic functions over large multipurpose handlers.

## 1.4 One Source of Truth

For any major concept, identify the authoritative state owner.

Examples:

- Active runtime subscriptions should be exact live filters.
- Desired subscriptions should be exact user-selected filters.
- Saved defaults should be persisted exact filters.
- Observed traffic should be historical evidence, not proof of current subscription state.

Do not let UI lists, registries, config files, and live runtime drift apart.

---

# 2. Dead Code Removal

## 2.1 Identify Before Removing

Before deleting code, classify it:

- definitely unused,
- duplicate of another path,
- obsolete testing artifact,
- old compatibility path,
- diagnostic-only,
- currently used but badly named,
- uncertain.

Only remove code that is clearly unused or replaced.

## 2.2 Search for References

Before removing a function, class, flag, config key, file, or UI control:

- search for direct references,
- search for string-based references,
- search for config references,
- search for event/callback references,
- search for tests or scripts using it,
- search documentation references.

## 2.3 Avoid Zombie Code

Remove code that:

- updates UI but not runtime behavior,
- updates registry but not the live system,
- is unreachable,
- is hidden behind obsolete flags,
- silently duplicates another handler,
- only exists because of an abandoned design.

## 2.4 Remove Old Comments That Lie

Update or delete comments that describe old behavior. Misleading comments are worse than no comments.

## 2.5 Remove Unneeded Comments

Remove comments that merely restate obvious code behavior, preserve outdated reasoning, or narrate temporary implementation details.

Keep comments only when they explain:

- non-obvious business rules,
- protocol-specific details,
- safety constraints,
- concurrency/threading assumptions,
- security-sensitive choices,
- intentionally unusual design decisions,
- TODOs that are specific, actionable, and still valid.

Do not use comments as a substitute for clear names, small functions, or simple control flow. If a comment is needed because the code is tangled, prefer simplifying the code.

## 2.6 Remove Old Test Artifacts

Temporary test code must not become permanent product behavior.

Remove or quarantine old test artifacts when they are no longer needed, including:

- test buttons that are no longer part of the workflow,
- debug flags that no current test uses,
- fake/stub success paths,
- obsolete diagnostic panels,
- hard-coded test topics, roots, channels, or node IDs,
- duplicated "temporary" handlers,
- abandoned safe/normal/test-mode branches,
- logs that were only added for a specific investigation and are now noisy.

If a diagnostic remains useful, move it behind a clearly labeled Advanced/Diagnostics area and document its purpose. Do not leave test artifacts mixed into normal user workflow.

## 2.7 Cleanup Must Improve Clarity

A cleanup pass is not complete if the code still has multiple competing paths for the same action.

After cleanup, there should be one obvious path for each of these operations:

- subscribe,
- unsubscribe,
- enable/disable source,
- apply desired subscriptions,
- restore defaults,
- save startup defaults,
- parse MQTT topics,
- accept/reject incoming packets.

## 2.8 Keep Useful Diagnostics

Do not remove valuable diagnostics just because they are not normal user features. Move them to an Advanced, Debug, or Diagnostics area if appropriate.

---

# 3. Redundant Code Resolution

## 3.1 Consolidate Repeated Logic

If the same rule is implemented in multiple places, consolidate it into a shared function or service.

Common examples:

- topic parsing,
- path construction,
- wildcard matching,
- config loading,
- save/load defaults,
- UI refresh after state changes,
- logging event messages,
- validation.

## 3.2 Avoid Parallel Implementations

Do not maintain multiple competing versions of:

- subscribe,
- unsubscribe,
- connect,
- reconnect,
- stage,
- apply,
- save defaults,
- parse topics,
- filter packets.

Pick one authoritative implementation.

## 3.3 Refactor Carefully

When resolving redundancy:

- preserve the public behavior,
- add targeted tests first if possible,
- change one layer at a time,
- avoid sweeping rewrites unless explicitly authorized.

## 3.4 Eliminate Fake Success Paths

A function that logs success without verifying success is dangerous.

Examples to avoid:

- "subscribed" when only a registry row was added,
- "disabled" when live packets are still accepted,
- "saved" when only memory state changed,
- "connected" when reconnect failed.

---

# 4. No Hard-Coded Values

## 4.1 Never Add New Magic Values

Do not hard-code values that should be configurable, discoverable, or named constants.

Avoid hard-coding:

- server names,
- ports,
- credentials,
- topic roots,
- file paths,
- user names,
- callsigns,
- device IDs,
- channels,
- time windows,
- retention limits,
- colors,
- UI dimensions,
- environment assumptions,
- OS-specific paths,
- API endpoints,
- retry intervals.

## 4.2 Use Named Constants for True Constants

If a value is genuinely fixed by a protocol or specification, define it once with a descriptive name.

Example:

```python
MESHTASTIC_MQTT_VERSION = "2"
```

Do not scatter `"2"` throughout the code.

## 4.3 Use Configuration for Environment Values

Environment-specific values belong in configuration, not code.

Good candidates:

- MQTT broker host,
- MQTT broker port,
- default topic filters,
- retention days,
- log level,
- startup defaults,
- UI preferences,
- database path,
- export path.

## 4.4 Provide Safe Defaults

Configurable does not mean uninitialized. Provide safe defaults in one place and document them.

## 4.5 Never Hard-Code Secrets

Never hard-code:

- passwords,
- tokens,
- API keys,
- private keys,
- session IDs,
- OAuth tokens,
- personal identifiers that do not belong in source.

Use environment variables, OS keychain, secrets manager, or local untracked config.

## 4.6 Validate Config

Validate configuration at startup and fail clearly if required values are missing or invalid.

---

# 5. Token Efficiency and Context Management

## 5.1 Read Only What Is Needed

Before reading large files, identify the likely relevant files and functions.

Prefer:

- targeted search,
- focused file reads,
- small diffs,
- summaries of existing behavior.

Avoid loading huge files unnecessarily.

## 5.2 Summarize Before Acting

For complex tasks, first summarize:

- what appears to be happening,
- files likely involved,
- intended change,
- risks,
- planned tests.

Then implement.

## 5.3 Avoid Repeating Large Context

Do not paste large unchanged code blocks back into discussion unless needed.

Use concise summaries and diffs.

## 5.4 Keep Instructions Close to the Change

When editing, focus on task-relevant sections. Do not opportunistically modify unrelated systems.

## 5.5 Preserve Important Findings

When investigation reveals important architecture or bug details, record them in project notes or comments where future work will find them.

## 5.6 Do Not Waste Tokens on Noise

Avoid:

- verbose speculation,
- restating obvious UI labels,
- dumping logs without analysis,
- repeating previous explanations,
- unrequested broad tutorials.

## 5.7 Prompt When a Different Model Would Be More Efficient

Before starting a non-trivial task, weigh token/cost efficiency against the capability the task actually needs.

- Mechanical, well-specified, narrow-scope work (implementing an already-clear design, fixing a located bug, a straightforward refactor) often does not need the most capable available model.
- Cross-system design, architecture decisions, ambiguous requirements, or auditing/reviewing work spanning multiple subsystems benefit from a more capable model even at higher token cost.
- If the model currently in use looks mismatched to the task in either direction, **prompt the user** with a brief, specific recommendation (which model, and the one-line tradeoff) before proceeding. Do not silently continue on a mismatched model, and do not switch models unilaterally — only the user can actually change the active model.
- Skip the prompt for trivial or already-mid-task work where switching would cost more than it saves.

---

# 6. Conservation of Runtime Resources

## 6.1 Avoid Unbounded Growth

Protect against unbounded growth in:

- logs,
- databases,
- in-memory packet lists,
- caches,
- UI tables,
- background queues,
- retained packet history.

## 6.2 Retention Policy

Any long-running app should have explicit retention behavior:

- max rows,
- max age,
- cleanup schedule,
- manual clear option,
- export before purge if needed.

## 6.3 Avoid Busy Loops

Use event-driven behavior or sensible sleep/backoff.

Never poll rapidly without a clear need.

## 6.4 Efficient UI Updates

Avoid refreshing large UI tables on every packet if batching is possible.

Use throttled updates for high-frequency events.

## 6.5 Backpressure

If incoming data exceeds processing capacity:

- queue safely,
- drop low-priority data intentionally,
- log rate-limited warnings,
- avoid freezing the UI.

---

# 7. Threading and Concurrency

## 7.1 Keep UI Work on the UI Thread

Never update UI widgets directly from worker threads.

Use thread-safe queues, signals, dispatcher calls, or scheduled UI updates.

## 7.2 Keep Blocking Work Off the UI Thread

Do not block the UI with:

- network calls,
- MQTT loops,
- file scans,
- large DB queries,
- exports,
- long cleanup tasks,
- discovery sweeps.

## 7.3 Use Clear Thread Ownership

Document which thread owns:

- network clients,
- database connections,
- queues,
- UI state,
- long-running workers.

## 7.4 Safe Shutdown

Every background worker should support clean shutdown.

On exit:

- stop accepting new work,
- flush or discard queues safely,
- unsubscribe/close network clients,
- close database connections,
- join threads with timeout.

## 7.5 Avoid Shared Mutable State

Prefer message passing or synchronized access.

If shared state is necessary:

- use locks carefully,
- keep critical sections small,
- avoid calling UI or network code while holding locks,
- avoid nested locks unless order is documented.

## 7.6 Race Condition Checks

Watch for races around:

- connect/disconnect,
- subscribe/unsubscribe,
- reconnect,
- mode changes,
- clearing windows,
- saving defaults,
- shutdown.

## 7.7 Idempotency

Operations should be safe to call more than once where practical.

Examples:

- subscribing to an already active filter should not duplicate it,
- unsubscribing a missing filter should not crash,
- reconnect should rebuild from the authoritative desired/saved set.

---

# 8. Best Use of Skills and Tools

## 8.1 Use the Right Tool for the Job

Use specialized tools when available.

Examples:

- spreadsheet tooling for spreadsheets,
- document tooling for document generation,
- slide tooling for presentations,
- PDF tooling for PDFs,
- official documentation for technical APIs,
- tests and linters for code validation.

## 8.2 Read Skill Instructions First

When using a specialized skill or tool, read its instructions before using it.

## 8.3 Prefer Primary Sources

For technical behavior, prefer:

- official documentation,
- source code,
- protocol specs,
- package docs,
- project README,
- tests.

Avoid relying on random forum posts unless investigating real-world quirks.

## 8.4 Do Not Invent Tool Behavior

If a tool or library behavior is unknown, inspect docs or code. Do not guess.

## 8.5 Use Small Verification Loops

After a change:

- run the narrowest relevant test,
- inspect output,
- fix,
- repeat.

Do not pile multiple untested changes together.

---

# 9. Security Best Practices

## 9.1 Secrets Management

Never commit secrets.

Use:

- environment variables,
- local ignored config,
- OS credential store,
- encrypted vault,
- user prompt at runtime if appropriate.

## 9.2 Input Validation

Validate anything that comes from:

- users,
- network,
- config files,
- databases,
- imported files,
- environment variables.

## 9.3 Safe File Handling

When reading/writing files:

- avoid path traversal,
- validate extensions where relevant,
- do not overwrite user files without confirmation,
- write atomically for important state,
- back up before migrations.

## 9.4 Network Safety

Use secure defaults when possible:

- TLS where supported,
- timeouts,
- retry limits,
- backoff,
- clear error messages,
- no infinite reconnect storms.

## 9.5 Least Privilege

Request and use the least permission necessary.

Do not expand permissions for convenience.

## 9.6 Logging Safety

Never log secrets, full tokens, passwords, private keys, or sensitive payloads unnecessarily.

For identifiers, consider partial redaction when appropriate.

## 9.7 Dependency Hygiene

Avoid adding dependencies unless they are justified.

Before adding one, consider:

- maintenance status,
- license,
- security history,
- package size,
- transitive dependencies,
- whether the standard library is enough.

## 9.8 Safe Deserialization

Do not deserialize untrusted data with unsafe mechanisms.

Avoid unsafe pickle/yaml loaders or equivalent.

---

# 10. Error Handling and Logging

## 10.1 Fail Clearly

Errors should say:

- what failed,
- where it failed,
- what value was involved if safe to show,
- what the app did next.

## 10.2 Do Not Swallow Exceptions Silently

If an exception is intentionally ignored, explain why in a comment and log if useful.

## 10.3 Avoid Log Spam

Use rate-limited logs for high-frequency events.

Do not log every packet unless debug mode is enabled.

## 10.4 Separate User Logs from Developer Logs

User-facing event logs should be understandable.

Developer logs can be more detailed but should be accessible only when needed.

## 10.5 Include Correlation Details

For stateful workflows, log identifiers such as:

- exact subscription filter,
- source name,
- root/channel/feed,
- operation type,
- result,
- timestamp.

---

# 11. Testing Requirements

## 11.1 Every Change Needs a Test Plan

Each session or change must include a test plan with exact steps.

A good test plan includes:

- startup test,
- targeted feature test,
- negative test,
- persistence test if relevant,
- rollback/safety test.

## 11.2 Acceptance Criteria

Define what "done" means before implementation.

Acceptance criteria should be observable and testable.

## 11.3 Test the Real Failure

When fixing a bug, test the behavior that actually failed, not just whether the app starts.

## 11.4 Regression Tests

If practical, add automated tests for:

- parsing,
- matching,
- validation,
- config load/save,
- diff computation,
- persistence,
- edge cases.

## 11.5 Manual Test Instructions

When automation is not practical, provide clear manual steps.

Include expected results.

## 11.6 Reconnect and Restart Tests

For long-running apps, test:

- restart,
- reconnect,
- disconnect,
- shutdown,
- restore defaults,
- persistence behavior.

## 11.7 Negative Tests

Test what should not happen.

Examples:

- disabled filter should not accept packets,
- invalid config should not start silently,
- duplicate subscribe should not create duplicate state,
- wildcard and specific filters should not overlap if prohibited.

---

# 12. Persistence, Config, and Migrations

## 12.1 Separate Runtime from Saved State

Do not confuse:

- session-only changes,
- desired runtime state,
- persisted startup defaults,
- safe factory defaults.

## 12.2 Save Intentionally

Do not persist experimental changes unless the user explicitly chooses to save them.

## 12.3 Atomic Writes

Write important config/state atomically:

1. write temp file,
2. validate,
3. replace original.

## 12.4 Backward Compatibility

When changing config schema:

- detect old schema,
- migrate safely,
- preserve unknown fields when possible,
- back up before destructive migration.

## 12.5 Clear Defaults

Document default values and where they are defined.

---

# 13. Subscription and Event-Driven Systems

This section applies to MQTT, event buses, message queues, and similar systems.

## 13.1 Exact Filters Are Authoritative

Track exact subscription filters, not vague labels.

Good:

```text
msh/US/SC/2/json/#
msh/US/SC/2/e/SCMesh/#
```

Bad:

```text
SC root active
derived subscription
normal mode root
```

## 13.2 Desired vs Active vs Observed

Keep separate:

- desired filters,
- active live filters,
- saved startup filters,
- observed traffic.

Do not infer active subscriptions from observed traffic alone.

## 13.3 Subscribe/Unsubscribe Must Touch Runtime

Adding a registry row is not subscribing.

Removing a UI row is not unsubscribing.

A live subscribe/unsubscribe path must call the actual client.

## 13.4 Packet Acceptance Must Match Active Filters

Every incoming packet should be matched against active filters.

If it does not match active filters:

- reject it, or
- flag it as unexpected diagnostic traffic.

## 13.5 Reconnect Must Use Desired/Saved State

Reconnect should not re-add old hard-coded filters.

Reconnect should restore the current authoritative filter set.

## 13.6 Wildcard Overlap

Avoid redundant overlapping filters unless intentionally supported.

Example:

```text
ROOT/2/json/#
ROOT/2/json/CHANNEL/#
```

The wildcard includes the channel-specific filter.

If overlap is not allowed, enforce it in one shared normalization function.

---

# 14. UI and User Experience

## 14.1 UI Should Match Mental Model

The UI should expose the real concepts users need and hide internal implementation details.

## 14.2 Avoid Debug Scaffolding in Normal UI

Temporary concepts should not remain in the primary workflow.

Move diagnostics to Advanced or Developer panels.

## 14.3 Preview Before Applying

For risky operations, show exactly what will change.

Examples:

- filters to subscribe,
- filters to unsubscribe,
- files to delete,
- config keys to change.

## 14.4 Reversible Actions

Provide safe reset/restore options where practical.

## 14.5 Clear Labels

Avoid labels like "active" or "connected" unless they are technically true.

## 14.6 Empty States

If a list is empty, explain why and what the user can do.

---

# 15. Performance and Database Hygiene

## 15.1 Index for Real Queries

If a table is queried by time, topic, node ID, source, or channel, ensure appropriate indexes exist.

## 15.2 Avoid Full Scans in Hot Paths

Do not perform large scans for every incoming packet.

## 15.3 Batch Writes

For high-frequency data, batch database writes when practical.

## 15.4 WAL and Cleanup

If using SQLite WAL:

- monitor WAL size,
- checkpoint periodically,
- run cleanup safely,
- avoid blocking the UI.

## 15.5 Retain Useful Data, Not Everything Forever

Define what data is permanent and what is rolling history.

---

## 15.6 Efficiency Is Also Response Time: Prompt Whenever You See a Way (owner rule, 2026-10-28)

Efficiency means token cost AND response time (wall-clock: how long the owner waits for a screen, a practice morning, a score, a build). Whenever you notice a way to make code faster or more efficient -- a hot query that scans too much, a result that could be cached, work that could run in parallel or in the background, a repeated start-up cost -- say so to the owner at that moment, even if it is outside the current task. Give the rough implementation time and the expected gain, measured where possible. The owner decides; do not silently skip it and do not silently build it unless the task already covers it.

# 16. Documentation Expectations

## 16.1 Update Docs with Behavior Changes

If behavior changes, update relevant documentation.

## 16.2 Document Non-Obvious Decisions

Explain why, not just what.

Examples:

- why wildcard and channel-specific subscriptions are mutually exclusive,
- why session-only changes do not persist,
- why approximate locations are plotted with uncertainty.

## 16.3 Keep User Instructions Practical

User-facing docs should describe workflows, not internal architecture.

## 16.4 Maintain a Known Issues List

When a limitation remains, document it clearly.

---

# 17. Refactoring Safety

## 17.1 Refactor in Layers

Preferred order:

1. add tests or diagnostics,
2. isolate current behavior,
3. introduce new shared function,
4. migrate callers,
5. remove old code,
6. test again.

## 17.2 Avoid Big Bang Rewrites

Unless explicitly authorized, do not rewrite an entire subsystem at once.

## 17.3 Keep Behavior Stable During Cleanup

A cleanup pass should not also introduce unrelated features.

## 17.4 Report What Changed

After refactoring, provide:

- files changed,
- code removed,
- duplicated paths consolidated,
- behavior preserved,
- risks,
- tests run.

---

# 18. Autonomous Work Expectations

When asked to work autonomously:

## 18.1 Create a Checkpoint First

Before broad changes:

- commit current state,
- create a branch,
- make a backup,
- or otherwise document a restore point.

## 18.2 Work Against Explicit Goals

Do not wander into unrelated improvements.

## 18.3 Test Until the Goal Passes

Do not stop at "compiled."

Run targeted tests until acceptance criteria pass or a blocker is clearly identified.

## 18.4 Stop on Dangerous Drift

If the work reveals a deeper issue, pause and report rather than piling hacks on top.

## 18.5 Deliver a Clear Final Report

Include:

- what changed,
- what was removed,
- what was tested,
- what passed,
- what failed,
- what remains,
- how to roll back.

---

# 19. Code Quality Checklist

Before declaring done, verify:

- no new hard-coded environment values,
- no secrets in source,
- no unused imports,
- no dead functions added,
- no duplicate code paths added,
- no unbounded loops or storage,
- no UI updates from worker threads,
- no silent exception swallowing,
- no fake success logs,
- no misleading UI state,
- no hidden persistence,
- tests or manual test plan included.

---

# 20. Standard Session Output Format

Use this format when reporting completion:

```markdown
## Summary

What changed.

## Files Changed

- file 1: reason
- file 2: reason

## Dead/Redundant Code Removed

What was removed or consolidated.

## Hard-Coded Values Removed

What was moved to config/constants.

## Security Notes

Any security-sensitive changes or confirmations.

## Threading/Performance Notes

Any relevant concurrency or performance considerations.

## Tests Run

Exact tests run and results.

## Manual Test Plan

Steps for the user to run.

## Known Limitations

What still does not work or was intentionally deferred.

## Rollback

How to return to the last known good state.
```
