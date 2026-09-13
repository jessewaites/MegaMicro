# AgentClock

**Your coding agents, on a pixel clock.**

AgentClock is a small macOS app that watches Claude Code, Codex CLI and friends,
and shows what they're doing on a 32×8 LED matrix sitting on your desk.

The point isn't the status display. It's this: **when an agent stops and waits
for you, the panel holds on it until you deal with it** — and clears itself the
instant you do. No notification to miss, no tab to check, no wondering whether
the thing is still running.

<!-- TODO: photo of the panel on a desk, mid-"needs you" -->

---

## What you need

| | |
|---|---|
| **Hardware** | A [Ulanzi TC001](https://www.ulanzi.com/products/ulanzi-pixel-clock-2882) (~$60), or any ESP32 board with a 32×8 WS2812 panel |
| **Firmware** | [AWTRIX NG](https://github.com/Blueforcer/awtrix-ng) — **not** the firmware it ships with, and **not** AWTRIX 3 |
| **Mac** | macOS 14 or later |
| **Agents** | Claude Code and/or Codex CLI. Others work too — see [Integrations](#4-turn-on-the-agents-you-use) |

---

## Setup

### 1. Flash the panel — do this first

**A new TC001 will not work with AgentClock out of the box.** It ships with
Ulanzi's own firmware, which has no network API at all — nothing can talk to it.
You have to replace that firmware with AWTRIX NG.

> [!IMPORTANT]
> **Back up the stock firmware before you flash, not after.** Flashing
> overwrites everything on the board, including the firmware it came with. If
> you ever want to go back, that copy is the only way.

Use the [AWTRIX NG browser flasher](https://blueforcer.github.io/awtrix-ng/getting-started/flashing/).

- It needs **Chrome, Edge or Opera**. Safari has no WebSerial and cannot flash.
- Do **not** raise the baud rate to 921600 on a TC001 — the firmware docs warn
  it can fail mid-write, and an interrupted write leaves the board unbootable
  until a later attempt succeeds.
- Prefer the command line? `esptool` works too; the flashing guide has the
  incantation.

> [!WARNING]
> **AWTRIX NG is not AWTRIX 3.** They share a name and nothing else — NG is a
> from-scratch rewrite with a completely different API. A panel running AWTRIX 3
> will look perfectly healthy and AgentClock still won't be able to drive it.
> AgentClock detects this case and tells you, but it's easier to just flash the
> right one.

### 2. Get it on Wi-Fi

After flashing, the panel has no network credentials. Wait ~15 seconds and it
opens its own Wi-Fi access point — join that and enter your network details.

Once it connects, **it scrolls its IP address across the display**. Write that
down; you'll want it in a moment.

Give it a DHCP reservation or a custom hostname if you'd rather not do this
again after a router reboot.

### 3. Build and run AgentClock

```sh
brew install xcodegen
xcodegen generate
open AgentClock.xcodeproj      # then ⌘R
```

Go to **Settings → Clock**. Panels announce themselves over Bonjour, so yours
should appear on its own — click **Use**. If your network blocks mDNS (common on
guest and corporate Wi-Fi), type the address in by hand.

**Test connection** confirms it and reports the panel size.

If something's wrong, the Clock pane tells you *which* thing:

| What it says | What it means |
|---|---|
| AWTRIX NG is running | Ready |
| Running AWTRIX 3, not NG | Wrong firmware — re-flash with NG |
| A board is plugged in over USB, but nothing on the network | Still on stock firmware; flash it |
| No panel found | Not on the network, or not flashed |

> AgentClock does not flash anything itself, on purpose. A failed write leaves
> the board unbootable, and the browser flasher already does this well. We'd
> rather not be in the path when someone's hardware breaks.

### 4. Turn on the agents you use

**Settings → Integrations**, one toggle each. Claude Code, Codex, Antigravity,
OpenCode, Copilot, Cursor and Qwen have installers.

Anything else can report over plain HTTP — no installer needed:

```sh
curl -s -XPOST http://127.0.0.1:48812/state \
  -d '{"source":"my-agent","state":"waiting","session":"1","cwd":"'"$PWD"'"}'
```

States are `idle`, `thinking`, `coding`, `waiting`, `success`, `error`.

### 5. Optional: show how much quota you have left

**Settings → Display → Claude usage.**

- **Codex** needs nothing. The CLI writes its own quota into its session files,
  so AgentClock just reads it.
- **Claude** doesn't record quota anywhere on disk. The numbers only exist in
  API response headers, so AgentClock reads your OAuth token from the Keychain
  item Claude Code created and makes one 1-token request a minute purely to read
  the headers off it. macOS will ask permission the first time.

Off by default. Codex's half works either way.

### 6. Let Claude or Codex write to the clock

In AgentClock's sidebar, open **AI Control**, then click **Connect** beside
Claude Code or Codex. AgentClock registers its bundled MCP bridge at
user scope, so it is available from any project. Then ask the assistant, for
example, “Make the clock say TESTING.”

The MCP tools are `show_message`, `clear_message`, and `clock_status`. The app
must be running when they are used. The bridge talks only to AgentClock on
`127.0.0.1`; the clock host and credentials remain in AgentClock and are never
copied into the assistant's configuration.

Messages always appear on AgentClock's on-screen simulator. When a physical
clock is configured, the same message is sent there too. Pass `animation` as
`stream` or `fall` for an animated entrance (`none` is the default).

The bundled bridge is also a small CLI, which is handy for diagnostics:

```sh
AgentClockBridge show TESTING
AgentClockBridge status
AgentClockBridge clear
```

---

## What you're looking at

One page per provider, rotating. Each page gets the whole panel.

```
┌────────────────────────────────┐
│  ▟▙  CLAUDE                    │   the mark, and who this page is about
│ ████ ▪▪ ▪▪ ▪▪                  │   one small creature per subagent
│  ▟▙  ██████░░░░░░░░            │   quota used
└────────────────────────────────┘
```

<!-- TODO: screenshots of the Claude page, the Codex page, and a held interrupt -->

**The mark's eyes carry the state.** The body keeps its brand colour so you can
tell Claude from Codex at a glance; the eyes change colour with what it's doing.

| Eyes | State | Meaning |
|---|---|---|
| Grey | idle | Nothing running |
| Blue | thinking | Working out what to do |
| Cyan | coding | Editing files, running commands |
| **Amber** | **waiting** | **Stopped and needs you** |
| Green | success | Finished |
| Red | error | Something went wrong |

**Subagents** appear as smaller versions of the same creature, each tinted by
its own state. **The bar** is quota used — green under 50%, amber to 80%, red
above. When there's no crew to show, the provider's name takes that space.

Every colour is editable, with live examples, under **Settings → Colours**.

**Interrupts** jump the queue. A "needs you" is **held** — it stays on the panel
through the whole rotation until that agent unblocks, then vanishes on its own.
Errors show briefly; completions are off by default and never wake a dark panel,
because nobody wants the room lit at 2am because a task finished.

When everything goes idle, AgentClock removes its pages and hands the rotation
back to the clock's own apps.

---

## Privacy

Hooks report **structural metadata only** — which agent, which state, which
directory. Prompts, tool arguments, file contents, diffs and results are never
sent anywhere.

Everything stays on your machine and your LAN. There's no cloud service, no
telemetry, no MQTT broker, no Home Assistant. The only outbound network call is
the optional Claude quota check, and that goes straight to Anthropic.

The hook shim has a 0.75s timeout and always prints a neutral response, so a
quit or crashed AgentClock can't block, slow or influence an agent.

---

## How it works

```
Claude Code / Codex / …
  └─ lifecycle hook fires
      └─ AgentClockBridge          normalizes it, ~10ms, fails open
          └─ POST 127.0.0.1:48812/state
              └─ AgentClock.app    session store → page planner → the panel
                  └─ PUT http://<panel>/api/v1/apps/pushed/ac-claude
```

Pages are **drawn**, not typed. Each is rendered to a pixel canvas and encoded
as AWTRIX `draw` commands, run-length compressed into lines — about 950 bytes
against an 8192-byte limit. That's what lets one page carry a mark, a crew and a
gauge at once, none of which the firmware's own text-and-icon layout can do.

It also means **the on-screen simulator and the panel render from the same
canvas**, so the preview can't drift from the hardware. There's a test asserting
a canvas survives the encode/render round trip unchanged.

---

## Running alongside MegaMicro

MegaMicro does the same agent
detection for a macro keyboard, and AgentClock's detection layer comes from it.
Both can watch the same agents at once:

| | AgentClock | MegaMicro |
|---|---|---|
| Webhook port | 48812 | 48802 |
| Hook marker | `#agentclock` | `#megamicro` |

Each installer only ever removes entries carrying its own marker, so installing
or removing one leaves the other's hooks untouched. The cost is one extra
short-lived process per hook event.

---

## Development

```sh
xcodegen generate
xcodebuild -scheme AgentClock test
```

139 tests, no hardware required. The page planner is pure — sessions in, pages
out — so every layout, colour, cap and interrupt is covered without a panel, and
the publisher's diffing and backoff run against a fake transport.

**Demo mode** — the button in Settings → Display, or `open AgentClock.app --args
-demo YES`. Opening titles, then a scripted fleet: one agent, a crew growing
under it, a block that holds the panel, a release, then Codex arriving so the
rotation has two pages. It goes through the same code path as real events, so it
drives a connected panel too — the fastest way to check the hardware.

**Icons** live in `Icons/src/*.json` as character grids you can read as pictures:

```json
{ "palette": {".": "#000000", "o": "#D97757"},
  "frames": [["..ooooooo..", "..ooooooo..", "..o.ooo.o.."]] }
```

```sh
python3 Icons/make_icons.py --preview
```

renders them to `Icons/build/*.gif` plus a magnified contact sheet. They can
also be traced from real artwork — see `accodex.json`. GIF rather than JPEG
because at 8×8 a JPEG is a single DCT block and a logo comes back ringing.

> A hard-won lesson, if you're adding a mark: **judge it at actual size, not
> magnified.** Dense logos that look full of structure when blown up reduce to
> scattered noise at 64 pixels. Strokes survive; texture doesn't. The Codex mark
> went through a blob and a knot before landing on `>_`.

```
AgentClockBridge/     the hook shim every agent CLI spawns
AgentClock/
  App/                AppModel — detection, publishing, config, demo
  Core/               AgentState, SessionStore, config, HTTP parsing
  Services/           webhook, hook installers, usage readers, firmware check
  Awtrix/             device client, discovery, page planner, publisher
  Matrix/             fonts, canvas, renderer, simulated panel, intro
  UI/                 menu bar + settings
Icons/                pixel-art sources and the GIF builder
```

Files under `Matrix/` named `*Lab*` and `TextLab`/`FleetStrip`/`UsageGauge` are
design scratchpads from working out the display, kept for reference. Nothing
ships depends on them.

---

## Notes and limits

- **32×8 is 256 pixels.** Text mostly doesn't work at this size; that's why the
  display is marks, colour and bars rather than words. The one exception is the
  provider's name in a 3-row font when there's nothing else to show.
- **The panel holds at most 50 pushed apps** and rejects payloads over 8192
  bytes. AgentClock stays well inside both.
- Pushed pages live in the panel's RAM and are lost on reboot; a periodic
  re-push restores them without you doing anything.
- The TC001's buzzer is a buzzer, not a speaker — RTTTL beeps only, off by
  default.
- **AWTRIX NG is licensed PolyForm Noncommercial 1.0.0.** That binds the
  firmware, not this app, but it's worth knowing.
