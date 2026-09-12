# Puppy

A small pet that sits on your desktop and shows you what every Claude Code session in
iTerm2 is doing right now. What it looks like is a swappable skin, and the one in the repo
is only a default. Put in your own cat, your avatar, or a plain colored square.

[![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](https://www.apple.com/macos/)
[![swift](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org)
[![terminal](https://img.shields.io/badge/terminal-iTerm2-blue)](https://iterm2.com)

[中文](docs/README.zh-CN.md)

![Bottom right of the screen: the pet, the stack of pending bubbles beside it, and the session list opened by double-clicking](docs/screenshot.png)

> The app's own interface is Chinese only at the moment. The mockups below show the real
> strings, glossed in English. Adding localization is a welcome PR.

## Contents

- [What this is](#what-this-is)
- [Installing it](#installing-it)
- [Using it](#using-it)
- [Further reading](#further-reading)
- [Contributing](#contributing)
- [License](#license)

## What this is

With five or six Claude Code sessions running, the one that costs you time is the one that
hit a permission prompt twenty minutes ago while you were looking somewhere else. Puppy
moves that into a corner of your screen: a small icon with no Dock presence and no
notifications. Its animation is the global state, the stack of bubbles beside it is your
to-do list, and clicking one puts you back in that terminal.

One look tells you which session is waiting on you: asleep means everything is idle,
glancing around means work is running, bristling and hopping means someone hit a permission
prompt. Things that need your hands stack up beside it, one card each, and never push each
other out. Clicking a card, or a row of the list, jumps to that iTerm2 window or tab. It
never posts a system notification or makes a sound.

What it looks like is up to you. The app knows four states (asleep, running, waiting on
you, just finished) and plays one frame animation per state. Whatever those four animations
actually draw is decided by the selected skin, and the one in the repo is a default that
happens to run out of the box.

It reads the live registry the Claude Code CLI keeps for itself: `~/.claude/sessions/<pid>.json`,
one file per running process. It never opens the transcripts under `~/.claude/projects/`,
which run to tens of megabytes. Install the optional Stop hook and "done" becomes what the
turn actually concluded. The reasoning behind all of this is in [docs/DESIGN.md](docs/DESIGN.md).

FSEvents throughout, with no polling anywhere: measured at 0% CPU while every session is
idle, and around 3% while the animation is actually playing. [What that buys and what it
costs](docs/DESIGN.md#省电).

**Requirements:** macOS 14+, a Swift 6 toolchain (Xcode or a standalone one), and iTerm2.
Focus switching goes through iTerm2's AppleScript interface, so a session living in some
other terminal has no window to raise and Puppy only brings iTerm to the front.

## Installing it

```bash
git clone https://github.com/wxdwfc/Claude-puppy.git
cd Claude-puppy
make run      # build the .app, sign it, launch it (kills any running instance first)
```

`make stop` quits. Generating the default artwork needs Pillow; without it Puppy still comes
up and falls back to the pixel skin compiled into the binary.

### Make a signing certificate (worth doing)

Without one, the build falls back to ad-hoc signing. That runs, but **the signature fingerprint changes
on every rebuild**, which keeps invalidating the "Puppy wants to control iTerm2" grant, and
you re-authorize every single time you click a session row. One self-signed certificate
settles it for good:

1. Open Keychain Access → Certificate Assistant → Create a Certificate…
2. Name it `puppy-dev`, identity type "Self Signed Root", certificate type "Code Signing"
3. Run `make run` again. The build script picks it up and signs with it.

The first time you click a session row, macOS asks for Automation permission once. Deny it by
accident and Puppy will walk you to System Settings → Privacy & Security → Automation.

### Optional: let the bubbles say something useful

```bash
make hook       # install the Stop hook into ~/.claude/settings.json (a .bak is kept first)
make unhook     # remove it cleanly
```

Without it, the bubble only says 跑完了 ("done"). With it, the bubble says what that turn
concluded:

```
╭─────────────────────────────╮
│ ✓ agentic-research        1m │
│ 补上了缺的重试逻辑,测试全过   │
╰─────────────────────────────╯◀ ⚡
```

It applies to every project, and **only sessions started afterward count**, so restart
anything already open. The channel is fenced inside the decoration layer: when a summary
can't be matched up, the bubble falls back to "done" and state detection is never touched.
[Why the hook isn't used for everything](docs/DESIGN.md#stop-hook-干的那件事).

## Using it

### Bossing it around

| Gesture | Result |
|---|---|
| **Click** | Move house: hop to the next corner of the current screen (bottom right, bottom left, top left, top right, around again) |
| **Double-click** | Open or close the session list |
| **Drag** | Put it wherever you want |
| **Right-click** | Open list / refresh / reset position / change skin / quit |

It has no Dock icon, and right-clicking it is the only way out.

When it covers something you need, you don't have to aim a drag at it. One click shoves it
to the next corner over, and every position is remembered. If you left it stranded in the
middle of the screen, the first click snaps it to the nearest corner before the rotation
picks up again. A double-click makes it hop once too, then it runs back before the list opens.

### What it's telling you

| Behavior | Meaning |
|---|---|
| Eyes shut, breathing, floating `z` | Everything idle, or no sessions at all |
| Glancing around, small bob | Something is running |
| Bristling, hopping, red `!` | **A session is waiting on you** (input or a permission prompt) |
| Grinning, bouncing, green `✓` | A turn just finished and nothing else is busy (10 seconds) |
| Green `✓` badge, top right | A turn just finished, but other sessions are still running or waiting (10 seconds) |

Body animations rank `waiting > running > just finished > asleep`, so as long as any session
is stuck on you, it is hopping. "Just finished" stays out of that contest. It hangs in the
top right as its own badge, which is what keeps it from being swallowed by the sessions
still running when you have several going at once. The badge and the red `!` land wherever
the skin puts them, and both can appear together. The left column above describes the
default skin; change it and the motions change with it, while the states do not.

### The stack beside it

A 6pt glyph over its head is far too easy to miss, so anything that needs your hands piles
up next to it, one card each:

```
╭──────────────────────╮
│ ✋ agentic-research   3m │   ← longest wait sits closest to it
│ 在等你 · permission prompt │     ("waiting on you")
╰──────────────────────╯◀ ⚡
```

- **The longest wait sits closest to it**, with shorter ones above. Clear the most urgent one and
  the next slides down to its mouth.
- Five cards at most. Anything beyond that folds into a single `还有 N 个 ›` ("N more") that
  opens the full list.
- **Clicking a card** jumps to that session's iTerm window, the same as clicking a row of the
  list. Jumping there does **not** clear the card. If you haven't actually answered
  it, it stays. There is no "mark as read" button, so you can't dismiss something and then
  forget you never dealt with it.
- A "done" card has nothing left to act on, so it clears itself after 60 seconds.
- The stack opens on its left, or flips to the right when the left is too tight. It steps
  aside while the list panel is open.

The stack is a direct reading of current state rather than a feed of notifications that age
out. [docs/DESIGN.md](docs/DESIGN.md#状态是从哪来的) explains why that distinction matters.

### Using your own skin

Drop a directory into `~/.puppy/skins/` and it appears under **right-click → skin** (the
menu rescans every time you open it, so nothing needs restarting). A skin is four filmstrip
PNGs, one per state, plus a `skin.json`:

```bash
./.build/debug/Puppy --export-skin ~/.puppy/skins/my-cat   # export the default as a template
./.build/debug/Puppy --render /tmp/px --skin my-cat        # render it before installing it
```

Besides frame rates, `skin.json` tells the app which row the bubble tail should point at and
where the `!` and `✓` badges go, which is how artwork of any proportion still lines up. The
field reference and the way per-frame bobbing is written are in [docs/SKINS.md](docs/SKINS.md).

The repo ships a vector-generated default (`make skin`), used until you pick something else.

### Command line (for debugging)

```bash
make list                    # print the current session table and bubble stack
make watch                   # keep printing state changes (driven by FSEvents)
make shot                    # regenerate the screenshot above (offscreen, no capture permission)
./.build/debug/Puppy --focus <pid>                 # test pid → tty → iTerm2 focus on its own
./.build/debug/Puppy --render <dir> [--skin <id>]  # render every frame of every state to PNG
./.build/debug/Puppy --skins                       # list available skins
```

## Further reading

- [docs/DESIGN.md](docs/DESIGN.md): where the states come from, the Stop hook trade-offs,
  how a parked turn gets rescued, power use, known rough edges
- [docs/SKINS.md](docs/SKINS.md): drawing your own
- [PLAN.md](PLAN.md): the original design sketch

All three are in Chinese.

## Contributing

Issues and PRs are welcome, especially these:

- **The registry schema drifted.** If `~/.claude/sessions/` sprouts a field or a status I
  haven't seen, paste one in (scrub anything sensitive out of the paths first).
- **Sprites you drew.**
- **Other terminals.** Only iTerm2 can be targeted precisely right now, because everything
  else fails to give back a tty that matches.
- **English strings in the app.** None of the UI is localized yet.

This is a personal toy project. Merges happen at weekend speed, so don't expect an SLA.

## License

MIT. The full text is in [LICENSE](LICENSE).
