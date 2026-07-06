# Project Context

- **Owner:** Brandon Martinez
- **Project:** automation-scripts — a personal macOS automation toolkit. Triggers orchestrated through Hazel (folder watch → wrapper → worker handoff). ~5,900 lines, almost entirely zsh with one Python helper.
- **Stack:** zsh (required), macOS + Homebrew, Hazel for event triggers, `launchd`/`cron`, external CLIs. Lint via shellcheck, format via shfmt.
- **Created:** 2026-07-06T16:26:54-04:00

## Role Focus

Event-Orchestration Engineer. I own `hazel/` and the trigger/queue/lock/worker plumbing that connects events to organizers. Concurrency-safe handoffs; deliberate event-source choices.

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

- Wrapper/worker handoff pattern: wrapper copies the file to a temp inbox (`~/Documents/.../_temp`), appends to `~/.<name>-queue`, then `& disown`s the worker. Worker holds a `mkdir "$lock"` mutex with `$$` in `$lock/pid`, reclaims stale locks via `kill -0`, `trap`s cleanup on EXIT, drains the queue, then truncates it.
- Rationale for copy-first: Hazel may move the original to Done immediately, so the worker must operate on a copy in the inbox.
