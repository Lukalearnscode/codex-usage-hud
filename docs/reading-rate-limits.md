# Reading the rate limits

This is the reusable part of the project. The panel is one thing you could
build on top of it; there are plenty of others.

A working version is in
[`examples/read_rate_limits.py`](../examples/read_rate_limits.py), which has no
dependencies and runs in about a second.

## Start the server

The Codex desktop app ships a headless server next to its UI:

```
/Applications/ChatGPT.app/Contents/Resources/codex app-server --stdio
```

Start it as a child process. Talk to it over stdin and stdout in JSON Lines:
one JSON object per line, with a newline (`0x0A`) at the end of each.

Start the executable directly, with `Process` or `subprocess`. Do not build a
shell command string.

## Never read the auth file

The server already holds the session of whoever is signed into the Codex app.
That is the reason to use it. Your code never touches `~/.codex/auth.json`,
never parses a token, never handles a credential.

Reading that file directly is easier. It is also the wrong answer. It puts you
in charge of someone else's credentials, and it breaks as soon as the storage
format changes.

## The handshake

Three messages, in this order:

| # | Message | Kind | Note |
|---|---|---|---|
| 1 | `initialize` | request | Has an `id`. Wait for the reply with the same `id`. |
| 2 | `initialized` | notification | No `id`. Nothing replies to it. Send it anyway. |
| 3 | `account/rateLimits/read` | request | Has an `id`. This is the actual question. |

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"your_app","version":"1.0.0"}}}
{"method":"initialized","params":{}}
{"method":"account/rateLimits/read","id":2}
```

Skip any of them and you get silence.

Buffer stdout and split on newlines as data arrives. One read is not one line.
It can give you half a message, or three at once.

## The reply

```json
{
  "id": 2,
  "result": {
    "rateLimitsByLimitId": {
      "codex": {
        "primary":   {"usedPercent": 47.0, "windowDurationMins": 300,   "resetsAt": 1788549878},
        "secondary": {"usedPercent": 23.0, "windowDurationMins": 10080, "resetsAt": 1789098711}
      }
    }
  }
}
```

Five rules:

**Prefer `result.rateLimitsByLimitId.codex`. Fall back to `result.rateLimits`.**
Older builds only have the flat one.

**Tell the windows apart by `windowDurationMins`, not by the key name.** `300`
is the 5-hour window. `10080` is the week. Do not assume `primary` is the short
one — those names describe position, the durations describe meaning.

**Clamp `usedPercent` to 0–100.** It can come back above 100, and it can be a
non-finite number.

**`resetsAt` is Unix seconds.** Work out the countdown yourself from the
current time.

**Ignore fields you do not recognise.** There are more of them than shown here,
and they are not yours to depend on.

## Staying up to date

The server sends `account/rateLimits/updated` notifications. Treat one as a
doorbell, not as data: when it arrives, send a fresh `account/rateLimits/read`
instead of trusting what the notification carries.

Add a slow fallback refresh as well — this project uses 60 seconds — plus a
refresh when the machine wakes and when Codex comes back to the front.

**Always time the request out.** The server can accept a request and never
answer it. If your client tracks "a read is in flight" and skips new reads
while one is, a lost reply freezes you forever with no error anywhere. This is
the single worst failure mode in the whole project, and
[Pitfalls](pitfalls.md#a-request-that-is-never-answered-freezes-everything)
explains how to reproduce it.

## When there is no data

If neither `rateLimitsByLimitId.codex` nor `rateLimits` is there, do not tell
the user to sign in.

Being signed out is only one reason that happens. A renamed field does it too.
Telling someone to re-authenticate over a protocol change sends them somewhere
with no fix at the end. Say what failed first, then offer the login as a
possibility rather than a diagnosis.

## Version warning

Everything on this page is internal to the Codex desktop app: the path, the
method names, the field names. None of it is published API. It was verified
against codex-cli 0.153.0 in September 2026 and can change in any release.
