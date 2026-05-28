# CLAUDE.md — TimeTrack conventions

Persistent rules for any Claude Code session in this repo. `DESIGN.md` owns
*what the tool does*; this file owns *how the code is written*.

## Architecture invariants (do not violate)

1. **Append-only event log.** Events are never UPDATEd or DELETEd. Every
   correction — idle reattribution, reconcile binding, history fix — is a NEW
   appended event applied at report time. If you find yourself writing an UPDATE
   or DELETE against `events`, stop; you're doing it wrong.

2. **`TimeTrackKit` is platform-agnostic.** No `import AppKit`, `import SwiftUI`,
   `import Combine`, no `NSSound`, no CoreGraphics. The kit must build and test on
   Linux. Platform side effects are *emitted as effects* and performed by the app.
   Idle input enters the kit only through the `IdleSource` protocol.

3. **No business logic in views.** SwiftUI views observe state and call kit APIs.
   State transitions, segmentation, reconcile rules live in the kit, always.

4. **The reconcile gate is strict and explicit.** Time is reportable only when
   bound to a Known Task with a real JIRA key. Nothing is auto-bound to overhead;
   overhead is just binding to the overhead JIRA. No heuristic ever decides
   "reconciled" — only an explicit `reconcile_bind` does.

5. **Bindings reference the registry id, not a key string.** This is what makes
   provisional-then-promote propagate. Never store the resolved JIRA key on the
   bind event as the target.

## Idle / escalation invariants

- Idle-start is `now − idleSeconds`, never detection time.
- Cycle freezes at the first unacked armed boundary; no phantom phases.
- Two segments max per episode (in-phase + overrun), per DESIGN.md.
- Escalation is presence-gated (active-seconds since return), never wall-clock,
  and the ceiling is a persistent notification — NEVER a focus-steal modal.

## Style

- Swift 5.9, macOS 14 deployment target.
- Prefer enums-with-associated-values + exhaustive `switch` for state; let the
  compiler enforce exhaustiveness (don't add `default:` that hides new cases).
- GRDB for persistence; WAL mode; foreign keys on.
- Keep functions readable over clever. This is a tool the author will iterate on
  heavily — optimize for "obvious in six months," not for line count.
- Comments explain *why* and *invariants*, not *what*.

## Two-process caveat (CLI + app)

If both `TimeTrackApp` and `timetrack-cli` touch `events.db` concurrently, rely
on SQLite WAL + a busy-timeout (a few seconds). Do NOT add a daemon or localhost
service — see DESIGN.md; it contradicts the standalone requirement. A Unix-domain
socket is a *deferred, maybe-never* fallback gated on observed contention only.

## Secrets

No tokens, keys, or `jira_cache.json` contents committed. `tools/jira-sync`
reads credentials from keychain/env. Add `.gitignore` entries for the app-support
data dir artifacts if any leak into the tree.

## When unsure

Ask, citing the DESIGN.md section. The design was reasoned through carefully;
silent reinterpretation — especially of the reconcile gate or idle segmentation —
is worse than a question.
