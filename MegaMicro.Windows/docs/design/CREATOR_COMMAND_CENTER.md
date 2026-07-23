# Creator Command Center

## Product direction

Creator Command Center turns the original Creator Micro into a general-purpose control surface for
local AI agents and high-frequency creator workflows. It borrows the useful product principles of
the Codex Micro—glanceable state, tactile commands, and contextual layers—without copying its
branding, icon set, key arrangement, or application interface.

The Windows application represents the original Creator Micro v1 according to its official QMK
`LAYOUT` geometry and the physical product:

- 12 RGB mechanical keys arranged as two top keys, two rows of four, and two bottom keys;
- a clickable horizontal roller at top-left and clickable rotary dial at top-right;
- two circular specialty controls in the bottom corners;
- counter-clockwise and clockwise actions for each encoder, for 20 bindable inputs total;
- shared RGB/underglow behavior that reflects the Creator Micro v1 VIA limitations;
- explicit connection, protocol, layer, and write-safety status.

## Default Codex layer

All 20 inputs have stable physical identities. Default labels cover common Codex actions such as new
task, focus Codex, approve, reject, review, test, explain, refactor, commit, push, documentation, and
reasoning adjustment. Every assignment remains layer-specific and editable.

## Information architecture

The first implementation should use eight destinations only:

1. Overview
2. Agents
3. Controls
4. Layers
5. Automations
6. Lighting
7. Diagnostics
8. Settings

Overview owns the three most important questions:

- Is the correct device connected and safe to use?
- Which agents or workflows need attention now?
- What will each physical control do on the active layer?

## Visual system

- Graphite shell: `#11151C`
- Raised panel: `#191F28`
- Primary text: `#F2F4F7`
- Secondary text: `#9BA6B5`
- Connected/complete: `#63E6A8`
- Working: `#F2BA4B`
- Waiting: `#A98BFF`
- Error: `#FF725E`

Status color must never be the only signal. Each state also receives an icon and plain-language
label. The layout targets WCAG AA contrast for normal text and preserves Windows keyboard focus
rings and high-contrast mode.

## Interaction rules

- Hardware reads may run automatically; any write path must be clearly labeled and user-invoked.
- Firmware flashing is outside this application.
- Opening the HID interface must remain shared, never exclusive.
- Focus Mode reduces the dashboard to the device twin, active agents, and urgent activity.
- Agent keys show the assigned agent name plus current state; action keys show the action name.
- Offline mode keeps assignments editable while disabling hardware-only actions.
- The activity timeline defaults to actionable state changes rather than raw diagnostic logs.

## Implementation slices

1. Maintain the QMK-derived Creator Micro v1 device twin and versioned control descriptors.
2. Add responsive agent/activity cards using the existing loopback session store.
3. Persist layers and control assignments in a versioned local JSON configuration.
4. Add accessible focus, hover, and state treatments.
5. Connect the dial/scroll and RGB paths only after protocol qualification and explicit write gates.
