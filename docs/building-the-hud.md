# Building the HUD

How the panel itself works. The [protocol side](reading-rate-limits.md) is
reusable; this part is one set of choices, and yours may differ.

## Why it runs all the time

If your process is not running, nothing can tell it that Codex just opened.
"Start when Codex starts" needs something already awake to notice. There is no
way around that.

So the app starts at login and stays in the background. It has no Dock icon and
no menu-bar icon (`LSUIElement=true` in Info.plist, plus
`NSApp.setActivationPolicy(.accessory)`). It shows the panel only while Codex
is in front. To the person using it, that looks the same as launching on
demand. It costs about 35 MB of memory.

## Starting at login

Try `SMAppService.mainApp` first. Fall back to writing a user LaunchAgent at
`~/Library/LaunchAgents/<label>.plist` with `RunAtLoad`.

The fallback is not optional. An ad-hoc-signed build usually cannot register as
a login item at all, so without it the app never comes back after a restart.

Either way the app's path gets recorded. Install it somewhere stable — not next
to your source checkout, and not in a folder you might clear out. If you do
move it, open it once so it can correct the recorded path.

## Finding the Codex window

Bundle ID: `com.openai.codex`.

Read window metadata with `CGWindowListCopyWindowInfo`. This needs no
Accessibility permission and no Screen Recording permission, because window
metadata is not window content.

Filter the list:

```swift
ownerPID == frontmostApp.processIdentifier
layer    == 0        // 0 means a normal window
alpha    > 0
width > 100 && height > 100
```

Then take the **largest one by area**. Not the first one. Codex puts temporary
windows in that list and they can come first, which parks your panel next to a
tooltip.

## Coordinates flip direction

`CGWindowListCopyWindowInfo` gives you top-left origin coordinates that grow
downward. AppKit windows use bottom-left origin coordinates that grow upward.

Only the **primary** screen's height converts between them:

```swift
let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? fallback
appKitY = primaryMaxY - quartzFrame.maxY
```

Two tempting mistakes, both invisible on a single display:

- Using the tallest screen's `maxY`. Fine until someone puts an external
  display *above* the built-in one. Then everything shifts by the height of the
  primary screen.
- Using `NSScreen.main`. That is the screen holding the key window, not the
  primary screen, and it changes as you move windows around.

`NSScreen.screens.first` is always the primary screen, and its frame origin is
always `(0, 0)`.

## Placing the panel

```swift
x = codexFrame.maxX - panelWidth - 12    // bottom-right of the Codex window
y = codexFrame.minY + 52
```

In AppKit coordinates `minY + 52` means 52pt above the bottom edge of the
window. An early version used `maxY + 52` and put the panel off the top of the
screen.

Update the position every 150 ms while Codex is in front, so the panel keeps up
when you drag or resize the window. Stop that timer when Codex is not in front.
Keep a 1-second watchdog as well: activation notifications on their own miss
window restores, full-screen transitions and waking from sleep.

## Panel properties

```swift
styleMask = [.borderless, .nonactivatingPanel]
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
panel.hidesOnDeactivate = false
panel.isFloatingPanel = true
panel.isMovableByWindowBackground = true
panel.ignoresMouseEvents = false
// canBecomeKey and canBecomeMain both return false
```

Three things people mix up:

| What you want | What controls it |
|---|---|
| Never steals your typing focus | `canBecomeKey` / `canBecomeMain` → `false` |
| Clicks go through to the app below | `ignoresMouseEvents = true` |
| You can drag it and right-click it | `ignoresMouseEvents = false` |

The last two cannot both be true. You cannot offer "clicks pass through" and
"drag it anywhere" at the same time. This build chose draggable. If you want
click-through, add a lock mode and say which one is active.

## Remembering where it was dragged

Save the position when the panel moves. Restore it at launch — but **check it
against the current screens first**.

A position saved on an external display that is no longer plugged in puts the
panel somewhere you cannot see. The only reset control is in the panel's own
right-click menu, so there is no way to recover from inside the app.

Require a real overlap before honouring a saved position:

```swift
PanelPlacement.isReachable(rect, visibleFrames: NSScreen.screens.map(\.visibleFrame))
// true only when at least 40x40pt of the panel lands on some screen
```

Check again on `NSApplication.didChangeScreenParametersNotification`, for the
display that gets unplugged while the app is running.

## Making the two rows line up

The panel uses Songti SC at 12pt. Every digit in that face is 5.628pt wide,
which helps. The unit letters are not:

| glyph | width |
|---|---|
| `m` | 9.42pt |
| `h` | 6.38pt |
| `d` | 6.17pt |

So `2h13m` and `6d11h` come out different widths, and everything after them
sits in a different place on each row.

Two ways to fix it:

**Pad every unit letter to the width of the widest one.** Lines up perfectly,
character by character. It also opens a gap on both sides of every letter, and
that looks worse than the original problem. We built this, looked at it, and
threw it away.

**Keep the digits and letters tight, pad once at the end.** `2h13m` and `6d11h`
stay solid. The difference goes into the single space before the trailing text,
which both rows already have. Both rows then end at the same x.

The second one ships. Both rows are measured together and the wider one decides
the width, so the gap is never bigger than it needs to be.

One trap: `NSAttributedString`'s `.kern` applies to **every character in the
range you set it on**. A 3.25pt pad on a five-character run adds 16.26pt, not
3.25. It has to go on the single space. We shipped that bug for one build and
the width assertion caught it.
