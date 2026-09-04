# Notes for agents

A macOS menu-bar-less companion app that reads Codex rate limits from the local
Codex app server and floats them over the Codex window.

Read these before changing anything:

- [docs/reading-rate-limits.md](docs/reading-rate-limits.md) — the protocol.
  Reusable on its own.
- [docs/building-the-hud.md](docs/building-the-hud.md) — the panel, window
  tracking, coordinates, typography.
- [docs/pitfalls.md](docs/pitfalls.md) — nine failures with reproductions.

## Rules that are not negotiable

**Never read `~/.codex/auth.json`** or any credential file. Authentication is
the app server's job. This is the whole security model.

**Always time out a rate-limit request.** A reply that never arrives will
otherwise freeze the client silently and permanently. See
[the first pitfall](docs/pitfalls.md#a-request-that-is-never-answered-freezes-everything).

**Identify rate-limit windows by `windowDurationMins`** (300 and 10080), never
by the `primary` / `secondary` key names.

**Ignore unknown fields.** Everything in the protocol is internal to the Codex
app and can change without notice.

## Rules for this codebase

**The two test files hold the same assertions.** Change
`Sources/CodexUsageHUDCoreTests/main.swift` and
`Tests/CodexUsageHUDCoreTests/RateLimitCoreTests.swift` together. On a Command
Line Tools toolchain only the first one actually runs; `swift test` compiles
without asserting.

**Verify a test by breaking the production code.** If the suite stays green,
the test is not testing what you think. This repository has one case of a fully
tested function the UI never called.

**Do not adjust the visual parameters casually.** Colours, Songti SC, column
widths, spacing and the narrow spaces were tuned against screenshots over many
rounds. The status column is a fixed 90pt with `.byClipping`, so text that gets
too wide is silently cut. Measure before changing a string: at 12pt each
Chinese character is 12pt wide.

**Countdown layout.** Digits and unit letters are set solid (`2h13m`); the
padding that aligns the two rows goes on the single narrow space before the
trailing text. `.kern` applies to every character in its range, so putting the
pad on the run multiplies it. Both rows are measured together in
`render(snapshot:)` and the wider one sets the width.

## Test hooks

Unset in normal use, present so hard-to-reach paths can be exercised:

| Variable | Effect |
|---|---|
| `CODEX_HUD_READ_TIMEOUT` | Rate-limit request timeout, seconds (default 15) |
| `CODEX_HUD_APP_SERVER_PATH` | Substitute app-server executable, for stubs |
| `CODEX_HUD_OUTPUT_DIR` | Packaging output directory (default `~/Applications`) |

To reproduce the frozen-client bug you need a stub that accepts a request and
never answers. `SIGSTOP` on the real server does not do it: a stopped process
stops draining its pipe, the write fails, and the normal recovery path kicks in.

## Commands

```bash
swift run -c debug CodexUsageHUDCoreTests   # 9 assertions, the real ones
swift build -c release
bash scripts/package_app.sh                 # build, test, sign, install
```
