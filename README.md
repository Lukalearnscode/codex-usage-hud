# Codex Usage HUD

Shows your Codex rate limits in a small panel on top of the Codex window.
It appears when Codex is in front, and hides when it is not.

![The HUD floating over the Codex window](docs/images/hud-in-context.png)

Native macOS app. No Electron. No Dock icon, no menu-bar icon.
It never reads your credentials.

![Close-up of the panel](docs/images/hud-closeup.png)

## Just want the numbers?

You do not need this app to see your limits. This script prints them, and it
has no dependencies:

```bash
python3 examples/read_rate_limits.py
```

```
 5-hour  ████████  100.0%  resets in 1h42m
 weekly  ████░░░░   47.0%  resets in 6d11h
```

It is about forty lines. If you are here to build your own thing, start by
reading [that file](examples/read_rate_limits.py) — it is the whole trick.

## Install

Needs macOS 13 or later and Xcode Command Line Tools. Nothing else.

```bash
git clone https://github.com/Lukalearnscode/codex-usage-hud.git
cd codex-usage-hud
bash scripts/package_app.sh
```

That builds it, runs the tests, signs it, and installs it to `~/Applications`.
Open it once and it will register itself to start at login.

Right-click the panel to refresh, reset its position, or quit. There is no
menu-bar icon, so that panel is the only place to control it.

To remove it: quit from that menu, delete the app, and delete
`~/Library/LaunchAgents/com.local.codex-usage-hud.plist`.

## How it works

**Where the numbers come from.** The Codex app ships a small server of its own.
You start it as a child process and ask it a question over stdin/stdout. It
already knows who is signed in, so your code never touches a token or an auth
file. Three messages and you have the data.
→ [Reading the rate limits](docs/reading-rate-limits.md)

**Why it appears only over Codex.** The app runs quietly in the background from
login. It watches which app is in front, finds the Codex window, and puts the
panel in its bottom-right corner. When you switch away, it hides the panel but
keeps running — a process that has exited cannot notice that Codex just opened.
→ [Building the HUD](docs/building-the-hud.md)

**What went wrong along the way.** A request that never gets answered can
freeze the whole thing silently. Window coordinates flip direction between the
two macOS APIs involved. A saved panel position can strand itself on a monitor
you unplugged. Nine of these, with how to reproduce each one.
→ [Pitfalls](docs/pitfalls.md)

## Before you rely on this

Verified against **codex-cli 0.153.0, September 2026, macOS 15, Apple Silicon**.

The executable path and every field name involved are internal to the Codex
app. None of it is a published API, and it can change in any release. So:
ignore fields you do not know, handle a missing one, and show a clear error
rather than a wrong number.

Also not verified: multi-monitor setups on real hardware (the coordinate rule
has unit tests, not a second display), and what the server returns when nobody
is signed in.

The build is ad-hoc signed, which is fine on your own machine. Handing it to
someone else needs a Developer ID signature and notarisation, or Gatekeeper
will block it.

## Tests

```bash
swift run -c debug CodexUsageHUDCoreTests    # 9 assertions
```

`swift test` also exists, but on a Command Line Tools toolchain it compiles the
tests without running them. The runner above is the one that actually asserts.
Both files hold the same checks; change one, change the other.

## License

MIT. See [LICENSE](LICENSE).
