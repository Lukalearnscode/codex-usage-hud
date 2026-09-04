# Pitfalls

Symptom first, since that is how you will meet these.

## A request that is never answered freezes everything

**Symptom.** The numbers stop updating. No error, no reconnect, no crash. The
panel keeps showing an old value for as long as you leave it.

**Cause.** A normal client keeps a `readInFlight` flag and clears it when the
reply lands. It also skips new reads while one is in flight, to avoid piling up
requests. If a reply never comes, the flag is never cleared, so every later
refresh — including the slow fallback one — hits that skip and returns
immediately. The child process is still alive, so the "process died" handler
never runs either. Nothing recovers.

**Fix.** Put a timeout on the request. When it fires, tear the connection down
and reconnect. Do not just clear the flag: a server that swallowed one request
is not healthy.

**How to reproduce.** `SIGSTOP` on the child does **not** work. A stopped
process stops draining its pipe, so your write fails and the normal
process-died path recovers on its own. You need a stub that reads the request
and never answers.

This project can point at one, with `CODEX_HUD_APP_SERVER_PATH` and
`CODEX_HUD_READ_TIMEOUT`. Three runs of 20 seconds each:

| Stub behaviour | Timeout | Child restarts |
|---|---|---|
| Swallows the request | 3s | 5 — detected and recovered |
| Replies normally | 3s | 1 — no false alarms |
| Swallows the request | 9999s | 1 — frozen, this is the bug |

## The app runs but nothing happens

**Symptom.** `ps` shows the process. No panel, no child process, no activity of
any kind.

**Cause.** `NSApplication`'s lifecycle never started, so
`applicationDidFinishLaunching` never ran.

**Fix.** Create `NSApplication.shared`, set the delegate, call `run()`.

**Worth knowing.** "The process exists" is not "the app started". Check for the
child process and for an actual window, e.g. through
`CGWindowListCopyWindowInfo`. Also note that running the raw executable from a
terminal is not the same as launching the `.app` — use `open`.

## `swift test` passes without running anything

**Symptom.** Green. Zero assertions executed.

**Cause.** Apple Command Line Tools ships no XCTest. SwiftPM compiles the test
target and reports "no tests found".

**Fix.** Keep a plain executable test runner next to the XCTest file and run
both. The packaging script here runs the executable one on every build.

**Worth knowing.** Break the production code on purpose and check the suite
goes red. A test that has never failed has never been shown to test anything.

## Testing a function the UI does not use

**Symptom.** The formatting helpers have full coverage and the panel still
draws something wrong.

**Cause.** The core layer had an eight-block progress bar function returning
`"████░░░░"`, well tested. The panel draws its own continuous bar and never
calls it.

**Fix.** Before trusting a test, search for calls to the function in the
production code. No hits means you are testing dead code.

## `.kern` multiplies by character count

**Symptom.** Text you padded by 3pt comes out 16pt wider.

**Cause.** `NSAttributedString`'s `.kern` adds that spacing after **every**
character in the range, not once at the end.

**Fix.** Put the padding on a single character.

**Worth knowing.** A width assertion catches this immediately. A visual check
might not, if you are looking at the wrong end of the line.

## A saved position can land on a monitor that is gone

**Symptom.** The panel does not appear, but the process is running fine.

**Cause.** The position was saved while an external display was connected. That
display is gone, so the coordinates point into empty space.

**Fix.** Validate a saved position against the current screens before using it,
and again when the screen layout changes. Require a real overlap, not just a
sliver — the reset control lives in the panel's own menu, so a panel you cannot
click is a panel you cannot reset.

## Window coordinates flip direction

**Symptom.** The panel sits at the top of the screen, or off it entirely.

**Cause.** `CGWindowListCopyWindowInfo` uses top-left origin coordinates.
AppKit uses bottom-left. An early version added an offset to `maxY` without
converting.

**Fix.** Convert with the **primary** screen's height, then position from
`minY`. Details in [Building the HUD](building-the-hud.md#coordinates-flip-direction).

**Worth knowing.** Two wrong versions of this look perfect on a single display.
Unit-test the conversion against made-up screen layouts.

## Grabbing the wrong Codex window

**Symptom.** The panel attaches itself to something small and odd.

**Cause.** Taking the first entry from `CGWindowListCopyWindowInfo`. Temporary
windows can sort ahead of the main one.

**Fix.** Filter by PID, layer 0, alpha above zero and a minimum size, then take
the largest by area.

## Ad-hoc signing plus a synced folder

**Symptom.** `codesign --verify --deep --strict` fails with a resource-fork or
Finder-information error on a bundle that verified a moment ago.

**Cause.** iCloud Drive or File Provider writes extended attributes into the
bundle after you signed it.

**Fix.** Stage and sign in a clean temporary directory, then copy the verified
bundle to its destination and clear extended attributes again. Better still,
keep the installed app out of a synced folder.

## Backup files inside `Sources/`

**Symptom.** `found N file(s) which are unhandled` on every build.

**Cause.** Editor or tool backups sitting in a SwiftPM target directory.

**Fix.** Move them out of the target and add them to `.gitignore`.
