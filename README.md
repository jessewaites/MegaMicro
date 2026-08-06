# MegaMicro

Your **Agent Keys** light up to reflect the live state of the task each agent is running —
thinking, waiting on you, finished, or errored — so a single glance at your keyboard tells you
exactly where everything stands. And don't let the playful colors fool you: this is a serious
tool for real work, just with a little more personality than your average one.

**Per-key RGB works on a stock Work Louder Creator Micro 2.** Each of the thirteen keys takes
its own colour from the agent assigned to it — not one aggregate colour for the whole board.
This was widely believed to be impossible on the Creator Micro 2 and locked to the OpenAI Codex
Micro; it isn't. See [How per-key lighting works](#how-per-key-lighting-works) for the mechanism
and the one trade-off it carries.

MegaMicro is a native Apple-platform app — a **general-purpose RGB AI keyboard configurator**
that maps live AI coding-agent activity onto a keyboard's RGB lighting and keys, turning it into
a physical command center for local AI agents. Assign agents to keys, see their state through RGB
lighting, jump to the agent that needs attention, and monitor a fleet without repeatedly searching
through terminal and editor windows. It ships with first-class support for the **Work Louder
Creator Micro 2** — including per-key RGB — and drives other Work Louder boards, such as the
OpenAI Codex Micro, through a device-agnostic layout model.
Companion apps bring the live dashboard to iPhone, iPad, and Apple Watch.

> [!IMPORTANT]
> MegaMicro is a general-purpose RGB AI keyboard configurator: it maps live AI-agent activity to
> per-key lighting and actions, driven by a device-agnostic layout model. It runs on **macOS 14 or
> later** and connects over **USB-C or Bluetooth Low Energy**.
>
> The **Work Louder Creator Micro 2** (`303A:8297` / `303A:8298`) is the primary, fully verified
> device. Per-key colour, perimeter lighting, key input, dial, and joystick work on real hardware
> with firmware **v0.6.1**; `303A:8298` is verified over Bluetooth. The **OpenAI Codex Micro**
> (`303A:8360`) shares the same firmware family and
> is matched by the same code path, but has not been tested on hardware. The original **Creator
> Micro v1** is supported through the separate `VIA` backend. More boards are addable through the
> same layout model.

![MegaMicro mirrored across the Codex Micro, iPhone, and Apple Watch — an agent needs attention, so the board, phone, and watch all glow red.](Assets/screenshots/hero.png)

*Live agent status on the Codex Micro, iPhone, and Apple Watch at once. Here an agent hit an error, so the whole fleet glows solid red (Steady glow enabled).*

## What it does

- Assigns individual agent sessions to physical keys using drag and drop.
- Shows agent states on the on-screen keyboard and on the keyboard's LEDs, one colour per key.
- Uses concise, human-readable states: thinking, working, waiting, finished, and error.
- Offers optional macOS notifications for agents that need input, fail, or finish; notifications
  are disabled by default so the keyboard remains the primary attention surface. Demo Mode can
  exercise these alerts when they are enabled.
- Stores local Prompt Snippets for repeatable multi-agent workflows. Three editable templates
  cover parallel planning, scoped implementation tracks, and final integration; custom snippets
  and optional placeholders can be copied without automatically pasting or submitting anything.
- Opens or focuses the appropriate agent, terminal, editor, or Conductor workspace when
  its assigned key is pressed.
- Provides a Dashboard and concise menu-bar activity feed for meaningful fleet events
  without exposing technical logs.
- Syncs the dashboard and remote focus controls to the iOS/iPadOS companion app over the
  local network, with QR-code pairing and Bonjour discovery.
- Relays fleet status to Apple Watch, including a watch-face complication for quick access.
- Supports simulated agents through Demo Mode for evaluation and video recording.
- Safely prepares an editable Work Louder Input layer by cloning the live protected Codex
  layout, with strict object discovery, backups, atomic replacement, and read-back validation.
- Keeps all telemetry local to the Mac.

<!-- Screenshot placeholder: Assets/screenshots/activity-feed.png -->
<!-- Suggested caption: Human-readable fleet activity and attention requests. -->

## Supported agent integrations

MegaMicro includes native integration installers for:

- Claude Code
- OpenAI Codex CLI
- Google Antigravity CLI
- OpenCode CLI and OpenCode Desktop
- Cursor IDE and Cursor CLI
- GitHub Copilot CLI
- Qwen Code

[Conductor](https://www.conductor.build/) is supported as the workspace and fleet layer.
Agent telemetry inside Conductor comes from the underlying Claude, Codex, Cursor, or
OpenCode integration.

Other tools can report state through MegaMicro's local webhook or the generic shell wrapper
shown in the Integrations screen. A logo appearing in Demo Mode does not necessarily mean
that the provider has a native integration.

## Supported apps and terminals

- **Conductor** — workspace discovery, assignment, telemetry routing, and workspace focus.
- **Ghostty 1.3+** — exact tab or split focusing by working directory and terminal title.
- **Mosaic** — dedicated shortcuts for its embedded Ghostty tabs and panes.
- **iTerm2** — exact tab or split focusing through `ITERM_SESSION_ID`, with a working-directory
  fallback for restored or legacy sessions.
- **Visual Studio Code** — workspace-window focus for agents running in the integrated terminal.
- **Warp** — project-window matching and app activation, plus a dedicated shortcut profile.
- **Kitty** — exact live-window focus through Kitty remote control when `KITTY_LISTEN_ON` is
  enabled; project-window fallback otherwise.
- **WezTerm** — exact pane focus through `WEZTERM_PANE` and `wezterm cli activate-pane`.
- **OpenCode Desktop** — native provider labeling, installation detection, and project routing
  through OpenCode's supported desktop deep link.
- **Cursor** — native user-level lifecycle hooks for the IDE and CLI, project-window focus for
  the desktop editor, and exact Ghostty/iTerm2 routing for Cursor CLI sessions.

Agent integrations and terminal integrations are independent: Claude, Codex, Cursor, OpenCode,
Qwen, and the other supported providers can report from any supported terminal.

## Companion apps

The **MegaMicro iOS/iPadOS app** discovers a Mac running MegaMicro over Bonjour, pairs by QR
code, and mirrors the device, agent assignments, RGB state, and activity feed. From the phone
or tablet you can reassign keys, clear assignments, dismiss agents, and ask the Mac to focus
the agent attached to a key.

The **Apple Watch app** receives dashboard snapshots through its paired iPhone and renders the
current fleet state locally. Its watch-face complication provides a quick launcher into the
watch dashboard. The Mac remains the local authority for integrations, keyboard hardware,
and application focusing; prompts and source code are not sent to the companion apps.

![The MegaMicro board mirrored to iPhone and Apple Watch, all glowing yellow for a waiting agent.](Assets/screenshots/companions.png)

*The same board mirrored to iPhone and Apple Watch — here an agent is waiting on input, so the fleet glows yellow.*

## Requirements

### To run the app

- A Mac running macOS 14 Sonoma or later
- A Work Louder **Creator Micro 2** (or OpenAI Codex Micro), on firmware **v0.4.0 or later** —
  v0.6.1 is what this is tested against. Older firmware such as v0.1.40 has no lighting API at
  all and every call returns "method not found"; see [Update the firmware, then quit Input](#2-update-the-firmware-then-quit-input).
- A USB-C data cable
- At least one supported local coding agent

The optional companion apps require iOS/iPadOS 17 or later or watchOS 10 or later. The Mac and
iPhone/iPad must be reachable on the same local network for initial discovery and pairing; the
Watch receives state through the paired iPhone.

The app and Demo Mode work without the physical keyboard, but real-key input and lighting
obviously require the device.

### To build from source

- Xcode with the macOS 14 SDK or newer
- [Homebrew](https://brew.sh/), recommended for installing XcodeGen
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Git

MegaMicro has no third-party runtime dependencies.

## Clone and build

Copy this repository's HTTPS or SSH URL from GitHub, then run:

```sh
git clone <repository-url>
cd MegaMicro
brew install xcodegen
xcodegen generate
xcodebuild \
  -project MegaMicro.xcodeproj \
  -scheme MegaMicro \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
open build/DerivedData/Build/Products/Debug/MegaMicro.app
```

Alternatively, run `xcodegen generate`, open `MegaMicro.xcodeproj` in Xcode, select your
development team under Signing & Capabilities, and run the MegaMicro scheme.

Because this app captures global keyboard events and communicates with USB hardware, macOS
may require you to grant permissions again whenever an unsigned or newly signed development
build moves to a different path.

## First-time setup

### 1. Grant macOS permissions

Open **Permissions** in MegaMicro and grant:

- **Accessibility** — captures the Micro's shortcuts globally, prevents those shortcuts from
  leaking into the foreground app, focuses agent windows, and sends configured actions.
- **Input Monitoring** — supports the fallback key listener and physical keyboard access.

When using the Ghostty or iTerm2 profile, macOS may also show a one-time **Automation** prompt
allowing MegaMicro to control that terminal. This permission lets an assigned agent key select
the exact tab or split; it does not give MegaMicro access to terminal contents.

If System Settings shows a permission as enabled but MegaMicro still reports it as missing,
remove the old MegaMicro entry with the `−` button, add the current app with `+`, and enable
it again.

Default terminal profiles send `F13` from the approval key instead of typing `y` followed by
Return into whichever app is focused. Bind `F13` only inside your agent's confirmation context.
For Claude Code, add this entry to `~/.claude/keybindings.json`:

```json
{
  "bindings": [
    {
      "context": "Confirmation",
      "bindings": { "f13": "confirm:yes" }
    }
  ]
}
```

### 2. Update the firmware, then quit Input

Install [Work Louder Input](https://worklouder.cc/input) and let it update the keyboard to
firmware **v0.4.0 or later** (v0.6.1 is what this is tested against). This step is not optional
on older boards: firmware v0.1.40 has no lighting API at all — every lighting call returns
`Method not found` — so the keys simply never light and nothing explains why.

During the update the pad reboots into its ESP32 bootloader and macOS asks **"Allow accessory to
connect?"** twice, first for *Espressif USB JTAG/serial debug unit*, then for *Work Louder Creator
Micro 2*. Allow both, and leave the cable plugged in until it finishes.

> [!IMPORTANT]
> **Quit Work Louder Input before starting MegaMicro**, and keep the ChatGPT/Codex desktop app
> closed too. Only one host can drive the keyboard's JSON-RPC channel at a time. Two hosts
> interleave their message fragments on the same channel and corrupt each other, which shows up
> as lighting that silently does nothing rather than as an error.

macOS may also show its own **Keyboard Setup Assistant** when the board is first plugged in,
because the pad enumerates as a real keyboard. Click **Quit** — it is unrelated to MegaMicro, and
"Continue" leads nowhere since the pad has no Shift keys to identify.

### 3. Connect the keyboard

**MegaMicro connects on its own at launch.** There is nothing to click. If the board is not
plugged in or paired yet, it keeps watching and grabs it when it appears.

On connect, MegaMicro programs the keyboard's active layer for you:

- The thirteen keys are bound to `KV_OAI_AG00`–`KV_OAI_AG12`, which is what makes per-key colour
  work (see [How per-key lighting works](#how-per-key-lighting-works)).
- The dial moves from volume control to `F18`/`F19`/`F20`, so it drives the mapped dial actions.
- Any per-layer lighting block left behind by another app is cleared, because a layer that
  carries its own lighting config ignores everything the host sends.

Your other layers are untouched. The bottom-left round button still switches layers in firmware,
so the stock behaviour — including the volume dial — remains one layer away.

To verify or troubleshoot, open **Diagnostics** and select **Run Hardware Probe**. The probe is
read-only. **Connect Keyboard (Go Live)** and **Release for Editing** are still there for
reconnecting manually or handing the board back to Input.

### How per-key lighting works

Per-key colour on the Creator Micro 2 needs three things at once, and the firmware reports no
error when any of them is missing — every call still answers `{"ok":1}` while lighting nothing.
That combination is why this was widely assumed to be impossible:

1. **Firmware v0.4.0+.** Earlier builds do not implement the lighting methods at all.
2. **Keys bound to `KV_OAI_AG*` keycodes on the *active* layer.** Bindings parked on another
   layer do nothing. MegaMicro reads `device.status` to find the live layer and writes there.
3. **Per-thread colours sent with the sync flags explicitly cleared.** Those fields latch on the
   device, so one stale "sync keys" flag from any previous app keeps washing the whole board in a
   single colour and quietly defeats per-key output.

**The trade-off:** a key bound to an agent keycode no longer types a character. It reports itself
to MegaMicro instead, which is what lets the app decide what each key does. In practice this is an
upgrade — no stray letters leak into whatever window has focus, and any key can run a skill, a
slash command, or a shortcut — but it does mean **those keys only work while MegaMicro is
running**. To hand the board back to Input or Codex, use **Release for Editing** in Diagnostics
and restore your keymap there.

### Handing the keyboard to another app

Only one app can drive the keyboard's JSON-RPC channel at a time. Running MegaMicro alongside the
ChatGPT/Codex desktop app or Work Louder Input does not fail loudly — the two hosts interleave
message fragments on the same channel and corrupt each other, so lighting silently stops working
in both. There is no error to find.

To hand the board over, use **Diagnostics → Release for Editing**. That clears MegaMicro's
lighting, puts the factory keycodes back so the keys type again, and drops the USB handle. Click
**Reconnect** to take it back.

On quit, MegaMicro always clears the lighting so the board is never left showing an agent state
that ended hours ago. It leaves the keys bound by default, since that is the normal working state;
**Settings → Keyboard → "Restore the keyboard when MegaMicro quits"** changes that if you switch
between apps often.

### 4. Install agent integrations

Open **Integrations** and install or reinstall each provider you use. MegaMicro preserves
unrelated configuration, creates private backups, and removes only its own marked entries
during uninstall.

Existing users upgrading from an older MegaMicro build should click **Reinstall** for Claude,
Codex, and Antigravity once so legacy curl commands are replaced by MegaMicroBridge.

Restart or reload the coding agent after changing its hooks. Then begin a harmless session,
for example:

```sh
claude -p "Reply with hello"
```

The on-screen key should move through working and finished states. Assign that agent to a
physical key from **Manage Agents**.

## Using MegaMicro

### Manage Agents

Live, unassigned agents appear as draggable chips. Drag a chip onto one of the six agent keys.
Pressing that physical key then focuses the corresponding agent or workspace.

Fleet filters show only agents that actually report a matching state. Conductor workspaces do
not claim an active/waiting/error state unless their underlying agent reports telemetry.

### Jumping to an exact terminal agent

Assigned agent keys are navigation controls. Pressing a physical key—or clicking its key on
the Dashboard or Manage Agents board—routes through the adapter for the active profile.

With the **Ghostty** profile active, MegaMicro uses Ghostty 1.3 or later's native AppleScript
API to select the exact terminal tab or split and bring its window forward, even when Ghostty
is behind Chrome or another application. MegaMicro first matches the agent-reported working
directory. If the agent and shell currently report different directories, it falls back to
the Ghostty-owned terminal title, allowing separately named Codex and Claude tabs to remain
independently addressable. Generic window matching never selects MegaMicro's own window.

With the **iTerm2** profile active, provider hooks record the terminal's inherited
`ITERM_SESSION_ID`. MegaMicro uses iTerm2's official reveal-session URL to select that exact
tab or split and raise its window. If an older saved session has no terminal ID, MegaMicro
falls back to iTerm2's reported working-directory variable.

With the **WezTerm** profile active, MegaMicro records `WEZTERM_PANE` and asks WezTerm's CLI to
activate that exact pane. With **Kitty**, it records `KITTY_WINDOW_ID` and the configured remote
control socket, then focuses that exact Kitty window. Kitty exact focus requires remote control
to be enabled with a listen socket; without it, MegaMicro safely falls back to the matching
project window and application.

The **Visual Studio Code** profile focuses the editor window matching the agent's reported
workspace. VS Code does not expose an external API for selecting a particular existing
integrated-terminal instance, so MegaMicro does not create a duplicate terminal to imitate
exact focus. **Warp** receives the same honest project-window fallback because Warp currently
has no supported external API for targeting a live pane.

For **OpenCode Desktop**, MegaMicro recognizes OpenCode as the provider and routes the assigned
project through OpenCode's supported `open-project` deep link whenever the desktop app is
already running. OpenCode CLI sessions continue to use their terminal adapter.

Conductor uses its own profile-specific workspace focusing path rather than terminal
automation. Other terminal applications can add their own focus adapters without changing
agent assignment or key behavior.

### Dashboard and Activity Feed

The Dashboard's Activity Feed explains important events in operator-friendly language, such as:

- “Claude on Key 2 needs permission or input.”
- “Codex on Key 5 encountered an error.”
- “Antigravity completed its current task.”

Use the filters to focus on attention requests, active work, or completed tasks. Technical
diagnostic output remains available separately under Logs.

### Demo Mode

Choose **Demo → Start Demo Mode** or press Command + Shift + D. Demo Mode creates a synthetic
fleet, rotates agent assignments, and demonstrates lighting and Activity Feed behavior without
starting real coding agents. All simulated events are labeled **DEMO**.

### Profiles and mappings

Profiles control actions, state colors, effects, and application-specific behavior. MegaMicro
can switch profiles based on the foreground application. Use the Keyboard and States & Colors
screens to customize the experience.

### Hardware layers

Hardware layers and MegaMicro profiles are separate:

- A **hardware layer** controls which events the keyboard firmware emits.
- A **MegaMicro profile** controls what this Mac does when it receives those events.

The bottom-left round button changes the keyboard layer in the stock firmware. MegaMicro also
maps that control to profile cycling when its semantic event reaches the app; automatic
layer-to-profile synchronization is not currently assumed.

The **Manage Layers** screen provides an assisted, version-sensitive workflow for copying the
live protected Codex layout into an editable layer. This preserves the six private Agent
events and live task-status LEDs, Codex commands, push-to-talk, dial behavior, and native
joystick behavior before individual positions are customized in Work Louder Input.

The workflow intentionally has narrow boundaries:

1. Open Work Louder Input with the Codex Micro connected and wait for it to finish retrieving
   the device configuration.
2. Fully quit Input using **input → Quit input**. Closing its window is not sufficient.
3. In MegaMicro, open **Manage Layers**, release the keyboard connection, and inspect the live
   configuration.
4. Confirm the displayed device, active profile, protected source layer, and editable target.
5. Clone the Codex layout. MegaMicro creates a full database backup and a separate backup of
   the target's original `layout`, then changes only that target `layout` using an atomic,
   permission-preserving replacement.
6. Open Input, select the target, temporarily append ` sync` to its name, and wait for
   `layout updated`. Restore the original name and wait for `layout updated` again.
7. Fully quit Input, reopen it once so it reads the device back, fully quit it again, and use
   **Verify Read-Back** in MegaMicro.

MegaMicro never modifies protected Layer 1 and does not write layer data directly to firmware.
It reads the live file at:

```text
~/Library/Application Support/input/input_storage.json
```

It refuses to proceed if the devices collection, Codex Micro, active profile, source layer, or
target cannot be identified safely. It does not install another user's database or fall back to
a hardcoded keymap. Work Louder Input still performs the actual device synchronization.

Backups are stored in:

```text
~/Library/Application Support/input/MegaMicro Layer Backups/
```

For rollback, first let Input synchronize the current device state and fully quit it. Use
**Restore Original Layer Layout** in the same Manage Layers session, then repeat the temporary
name change and read-back steps. Rollback restores only the target `layout`; it deliberately
preserves current database metadata and hardware checksums. A fresh full database backup is
also created immediately before rollback.

This integration is unsupported by Work Louder and may break when Input, its storage schema,
the Codex Micro firmware, or private `KV_OAI_*` keycodes change. It was designed from the
workflow verified with Input 0.17.2 and Codex Micro firmware 0.4.1, but always inspects the live
configuration instead of assuming those versions.

## Local webhook

Any local tool can report a state directly:

```sh
curl -X POST http://127.0.0.1:48802/state \
  -H 'Content-Type: application/json' \
  -d '{
    "source": "my-agent",
    "state": "coding",
    "session": "stable-session-id",
    "cwd": "/absolute/path/to/project"
  }'
```

Accepted states are:

```text
idle  thinking  coding  waiting  success  error
```

Optional metadata includes `agent`, `parentSession`, `model`, and `task`. The service listens
only on `127.0.0.1`; `GET /health` and `GET /sessions` are also available locally.

## Privacy and security

- Agent state remains on the local Mac.
- The webhook binds only to the loopback interface.
- MegaMicroBridge forwards structural metadata, not raw prompts, commands, diffs, tool
  results, or error contents.
- Hook requests use short timeouts and fail open so a closed MegaMicro app does not block an
  agent.
- Configuration changes are backed up, written with private permissions, and rejected when
  existing JSON is malformed.
- Activity logs rotate and are stored under the user's Application Support directory.

MegaMicro is intentionally not App Sandbox-enabled because system-wide event capture, local
agent configuration, Accessibility automation, and raw HID access require capabilities outside
the sandbox. Hardened Runtime is enabled.

## Troubleshooting

### The app opens and immediately disappears

MegaMicro remains available through its Dock and menu-bar icons. When running a development
build from Terminal, use the full build-and-open commands above rather than executing an
intermediate binary directly.

### The keyboard is not detected

- For USB-C, confirm the cable carries data, not power only.
- For Bluetooth, confirm the keyboard is paired and connected in System Settings.
- Quit Work Louder Input so it releases the device interface.
- Grant Input Monitoring.
- Run Diagnostics → Run Hardware Probe and copy the resulting report.

### The keyboard goes dead after editing layers in another app

Editing the board's layers in a VIA-based configurator (such as Work Louder Input) makes the
keyboard re-enumerate over USB, which briefly drops MegaMicro's connection. MegaMicro now
**auto-reconnects** — it retries with backoff and re-grabs the board once it reappears, so the
lights come back on their own within a few seconds. The same recovery covers cable jiggles,
USB-hub power blips, and firmware updates.

If you *plan* to edit layers, open Diagnostics and use **Release for Editing** first. This frees
MegaMicro's HID connection and pauses auto-reconnect so the two apps don't contend for the board;
press **Reconnect** when you are done.

If the board stays unresponsive even to other apps, its host-side USB binding has wedged — MegaMicro
can only release its own connection, not the system's. **Unplug and replug the USB-C cable** to force
a fresh enumeration (a full restart is not required).

### Keys do not trigger actions

- Confirm Accessibility is granted to the exact MegaMicro build currently running.
- Re-add the permission after rebuilding or moving the app.
- Confirm the Work Louder keymap matches MegaMicro's trigger table.
- Open Permissions and use **Retry Event Tap**.

### An agent never appears

- Open Integrations and confirm its adapter is installed.
- Reinstall after upgrading MegaMicro.
- Restart the provider so it reloads its hook configuration.
- Confirm MegaMicro's webhook reports healthy.
- Check Logs for the most recent integration event.

### An assigned Ghostty agent key opens the wrong tab—or no tab

- Confirm the active profile is **Ghostty**; terminal focusing is intentionally profile-specific.
- Use Ghostty 1.3 or later and ensure `macos-applescript` has not been disabled.
- Accept the macOS Automation prompt for MegaMicro → Ghostty. If previously denied, enable it
  under System Settings → Privacy & Security → Automation.
- Confirm the Ghostty terminal's working directory or tab title identifies the assigned project.
- Check Logs for `focused Ghostty terminal` or a Ghostty automation permission error.

## Development

Run the test suite with:

```sh
xcodegen generate
xcodebuild \
  -project MegaMicro.xcodeproj \
  -scheme MegaMicro \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Project structure:

```text
MegaMicro/
├── App/          application state, subsystem wiring, and render loop
├── Core/         models, configuration, HTTP parsing, state machine, and effects
├── Devices/      keyboard protocols (v.oai + VIA), HID transport, simulator, and diagnostics
├── Services/     integrations, bridge installation, focus, input, and workspace tracking
└── UI/           menu-bar panel and configuration screens
MegaMicroBridge/  provider hook normalization command-line executable
MegaMicroTests/   state, protocol, installer, security, and fixture tests
MegaMicroiOS/     iPhone and iPad dashboard, pairing, and remote controls
MegaMicroWatch/   Apple Watch fleet monitor
MegaMicroComplication/ watch-face launcher complication
MegaMicroShared/  shared brand assets for companion targets
Assets/           logos and images
```

`project.yml` is the source of truth for the Xcode project. Generated `.xcodeproj` files are
ignored by Git and should not be edited manually.

## Contributions wanted

MegaMicro is a general-purpose RGB AI keyboard configurator, but its hardware support ships for
Work Louder boards today. It should not stay tied to one vendor — we would welcome a focused pull
request that adds a **small built-in keyboard preset catalog** without trying to become a universal
keyboard-hardware driver (arbitrary detection, flashing, and RGB) in one step.

### Small keyboard preset catalog

The first version should add a short list of compact, AI-agent-friendly layouts alongside the
Codex Micro preset:

- 2×3 macro pad
- 3×3 macro pad
- 3×4 macro pad
- 4×4 macro pad

The existing `KeyboardLayout` model and VIA/KLE import path already make the keyboard geometry
data-driven. The main work is product integration and making sure each preset behaves cleanly
throughout the app.

A suitable pull request should:

- Let users select a built-in preset from the Layouts screen.
- Render every preset correctly in the macOS editor and the iPhone and Apple Watch monitoring
  views, without clipping, broken spacing, or unusably small keys.
- Preserve each layout's key legends and bindings when switching layouts.
- Define an explicit logical key order for agent-host keys, hotkeys, and simulated LED state.
- Keep trigger bindings isolated per layout, including a safe migration path for existing Codex
  Micro users.
- Add focused tests for preset geometry, selection, persistence, and trigger lookup.
- Update screenshots or documentation when the visible UI changes materially.

This visual preset support is deliberately separate from physical hardware support. Adding a
preset does **not** mean MegaMicro can detect, light, or program a matching USB keyboard. A preset
pull request should describe that distinction clearly in the UI and documentation.

### Larger keyboard-platform ideas

We are also interested in these follow-on projects, but contributors should open an issue and
agree on the design before starting a large implementation:

- Importing QMK `info.json` keyboard definitions.
- A versioned keyboard-definition format covering geometry, USB identity, trigger mapping, LED
  mapping, and driver capabilities.
- Hardware backends for QMK-compatible devices or OpenRGB-supported keyboards.
- A visual keyboard-layout designer and a shareable community preset catalog.
- Carefully selected presets for larger ortholinear, 40%, 60%, 75%, TKL, or full-size keyboards
  once the compact-layout UI has proven itself.

For now, full USB discovery, arbitrary RGB drivers, a universal keyboard database, and a complete
layout designer are intentionally out of scope. Keeping the first contribution small will let us
learn whether people actually want broader keyboard support before committing to a much larger
architecture.

### Agent integration ideas

MegaMicro reflects any agent that reports its state — today via per-agent hooks that POST to the
local webhook. We also welcome new *sources*, especially ones that report state a different way:

- **[Herdr](https://github.com/ogulcancelik/herdr)** — a terminal agent multiplexer that already
  tracks per-pane agent states (`working` / `blocked` / `done`) and streams them over a local
  socket API. Rather than installing hooks, MegaMicro would connect as a read-only client and
  subscribe to its state-change events — a strong fit for the agents where Herdr is the lifecycle
  authority (Pi, OMP, OpenCode, and others). Design and open questions:
  [#1](https://github.com/jessewaites/MegaMicro/issues/1).

## Current project status

MegaMicro is an early-stage project. The software simulator, agent state engine, integrations,
and configuration UI are functional.

Physical hardware support is verified on **Creator Micro 2 firmware v0.6.1**: per-key colour,
perimeter lighting, key presses, the dial, and the joystick have all been exercised on real
hardware. USB is verified on `303A:8297`; Bluetooth Low Energy is verified on `303A:8298`.
Treat other combinations as experimental, particularly the **OpenAI Codex Micro** (`303A:8360`),
which shares the firmware family and code path but has not been tested on a physical unit.
Behaviour across other firmware revisions has not been surveyed.

Bug reports should include:

- macOS version
- MegaMicro commit or release version
- Coding-agent name and version
- Whether the problem occurs in Demo Mode, the on-screen simulator, or physical hardware
- A copied Diagnostics report when hardware is involved

## License

No open-source license has been added to this repository yet. Add a `LICENSE` file before the
public GitHub release so contributors and users have clear terms for using and modifying the
code.
