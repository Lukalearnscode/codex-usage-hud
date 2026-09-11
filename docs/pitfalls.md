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

## Frosted glass does not work on a borderless panel

**Symptom.** `NSVisualEffectView` renders as a flat slab of colour. Nothing
behind the window shows through, in either appearance.

**Cause.** Two separate things, and fixing only one leaves it looking fixed
while it is not. `blendingMode = .withinWindow` blends against sibling views
inside the same window, and a backing view at the bottom of a panel has no
siblings to blend with. Setting `wantsLayer` plus layer properties directly on
the effect view replaces the backdrop layer the system draws the material into.

**Fix.** Neither, in the end. `.behindWindow` plus a container view for the
corner radius still produced a flat slab on a `[.borderless,
.nonactivatingPanel]` window across three attempts. What does work is a plain
translucent background colour: window-server alpha compositing does not depend
on the material system at all. You lose the blur and keep the translucency.

**How to check.** Sample the panel interior at several points in a screenshot.
A perfectly uniform value means nothing is showing through, no matter how
translucent it looks. Three rounds of this read rgb(173,172,170), then
rgb(146,144,140), then rgb(111,111,110) — the colour changed each time, so the
code was taking effect, and the interior was uniform every time, so the
translucency never was.

## The system appearance is not the app's theme

**Symptom.** A panel that follows the system appearance looks wrong against the
app it floats over. Light-mode styling appears never to be applied.

**Cause.** macOS has a system appearance, and an app can have its own theme
setting that disagrees with it. A dark system running an app themed light gives
you a dark panel on a light window, and every light-mode code path stays
untouched.

**Fix.** Give a cross-application overlay its own light/dark/follow-system
setting instead of binding it to `NSApp.effectiveAppearance`. Detecting the
underlying window's brightness automatically would need Screen Recording
permission, which is rarely worth it.

**How to check.** `defaults read -g AppleInterfaceStyle` reports the system
appearance. Read it before concluding that a light-mode branch is broken.

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

## The free plan has one window, and the parser said nothing

**Symptom.** The subscription lapses and the panel greys out to "数据滞后"
(stale) for days, still showing the last paid-plan numbers. The log is empty.

**Cause.** On the free plan `account/rateLimits/read` returns a single
`primary` window of 43200 minutes (30 days), `secondary` is `null`, and
`planType` is `"free"`. The parser only accepted the 300 and 10080 minute
windows, so every reply was `.invalid`, no new snapshot was stored, and the
`.invalid` branch did not log. Six days passed before anyone noticed.

**Fix.** Keep every window the server sends, sorted shortest first, and name
rows by duration instead of hard-coding two slots. Log the "parsed but no
usable window" case. Add a test with the verbatim free-plan reply so the shape
is pinned.

**How to check.** `python3 examples/read_rate_limits.py` prints whatever
windows exist; on the free plan that is one `30-day` line.

## An attributed string ignores the label's alignment

**Symptom.** Two rows in the same 90pt status column: the countdown starts at
the column's left edge, a plain label set with `stringValue` lands flush right,
about 17pt further over.

**Cause.** The label has `alignment = .right`. The countdown is set with
`attributedStringValue` and carries no paragraph style, so NSTextField draws it
from the leading edge and the `.right` setting never applies to it. The plain
string does honour it. Same column, two rules.

**Fix.** Set every text that must line up with the countdown as an attributed
string too, with the same font and colour attributes. Or give both a paragraph
style; either way, pick one path for the whole column.

**How to check.** Render the panel to a bitmap with
`view.cacheDisplay(in:to:)` at 2x and measure. It needs no screen-recording
permission, and the HUD does it when `CODEX_HUD_DUMP_PNG=/path` is set.
