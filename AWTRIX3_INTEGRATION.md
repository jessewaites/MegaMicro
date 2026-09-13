# AWTRIX 3 / Ulanzi TC001 integration

Planned after the Ulanzi TC001 arrives.

## First version

Add an optional, one-way AWTRIX 3 output to Mega Micro. Mega Micro should send its existing
Claude Code and Codex CLI lifecycle events directly to the clock over the local network using
the AWTRIX HTTP Custom App API:

```text
POST http://<clock-ip>/api/custom?name=MegaMicro
```

No Home Assistant, MQTT broker, cloud service, or companion daemon should be required. Keep
MQTT as a possible future transport, but prefer HTTP for the initial implementation.

Display information already available in Mega Micro:

- provider (Claude Code or Codex)
- lifecycle state: idle, thinking, coding, waiting, success, or error
- project/task label when it fits
- elapsed session time, calculated from `AgentSession.startedAt`
- active-agent count or a compact fleet summary
- prominent waiting, completion, and error notifications

Do not implement token-usage tracking in the first version.

## Visual direction

Create tiny pixel-art Claude and Codex marks suitable for the TC001's 32x8 RGB matrix. Use the
provider artwork only as visual reference and simplify it substantially for legibility at that
resolution. Pair each mark with short text and Mega Micro's existing state colors. Possible
pages include `CODEX 12m`, `CLAUDE WAIT`, and `3 AGENTS`.

Prefer AWTRIX custom-app pages for ongoing status and AWTRIX notifications for brief events
such as permission requests, errors, and session completion. Updates should be rate-limited and
sent only when the rendered content changes, plus a low-frequency refresh if AWTRIX requires it.

## Implementation shape

Add a small AWTRIX publisher/service inside the macOS app that observes `SessionStore`, formats
the current state for a 32x8 display, and sends JSON with `URLSession`. Add settings for:

- enabled/disabled
- clock hostname or IP address
- refresh behavior
- which status pages and notifications are shown

The integration must remain optional, local-only, fail open, and must never delay agent hooks or
normal Mega Micro operation when the clock is offline.

## When the hardware arrives

1. Flash and configure AWTRIX 3, then give the clock a stable local hostname or DHCP reservation.
2. Confirm the Custom App endpoint and payload against the installed firmware version.
3. Prototype text, colors, pixel icons, transitions, and notification behavior on the real 32x8 matrix.
4. Implement the service and preferences in Mega Micro.
5. Test reconnect/offline behavior and ensure repeated updates do not flood the clock.

## Deferred: remote control directly from the display

**Status: intentionally postponed.** The preferred long-term experiment is to let the AWTRIX
device receive remote content without requiring MegaMicro, AgentClock, a Mac, or a Raspberry Pi
to remain online. Do not start this work until AWTRIX-NG has had more time to stabilize and there
is enough project bandwidth to maintain a firmware fork.

Do not attempt to run Tailscale on the ESP32 and do not expose the clock's HTTP server through a
router port-forward. A public IP plus Basic Auth would leave the embedded web server and firmware
directly exposed, and would still require solving dynamic addressing, TLS, brute-force protection,
and secure credential storage.

Instead, fork AWTRIX-NG and add a small **outbound HTTPS command client**:

```text
Remote browser or phone
          |
          | HTTPS: publish a validated display command
          v
Small hosted control service
          ^
          | outbound HTTPS poll from the ESP32
          |
   AWTRIX-NG display
```

The display remains behind the home router. Every few seconds it asks the hosted service for the
next command, authenticating with a unique random device token. This avoids inbound firewall rules,
works with changing home IP addresses, and keeps the clock independent of other computers.

### Proposed protocol

Keep the protocol deliberately narrow and versioned. One possible exchange:

```http
GET /v1/devices/<device-id>/commands?after=<last-command-id>
Authorization: Bearer <device-token>
```

```json
{
  "id": 184,
  "type": "custom_app",
  "payload": {
    "text": "I ❤️ CW",
    "effect": "rain",
    "duration": 30
  }
}
```

After validating the command, the firmware should pass it into AWTRIX's existing custom-app,
notification, or drawing pipeline rather than introducing a second renderer. Persist only the last
successfully applied command ID so a reboot does not replay old messages. Use exponential backoff
with jitter when the service is unavailable; local clock features must continue normally while
remote control is offline.

### Security requirements

- Use HTTPS with certificate verification. Never send credentials or content over plain HTTP.
- Give each display a generated, high-entropy token; do not use the human-facing password as the
  device credential.
- Store only a salted password hash in the hosted service. Provide token rotation and revocation.
- Accept a small allowlist of command types and known effects. Never accept shell commands,
  arbitrary URLs, firmware URLs, or executable code.
- Enforce maximum JSON, text, frame, animation, and duration sizes on both server and firmware.
- Rate-limit login, publishing, and device polling endpoints.
- Prevent one account/device from reading or publishing another device's commands.
- Expire commands so an old romantic message or alert cannot unexpectedly appear days later.
- Do not include Wi-Fi credentials, device tokens, or private content in routine logs.
- Keep firmware updates on AWTRIX's existing trusted update path; remote display control must not
  become a second OTA mechanism.

### Hosted control service

The first server should remain intentionally small:

- a password-protected responsive page for text, color, icon, effect, and duration;
- an authenticated endpoint that creates validated commands;
- an authenticated device polling endpoint;
- a minimal command/status store with creation, delivery, expiry, and acknowledgement timestamps;
- basic audit information without storing secrets or unnecessary message history.

The service should generate ordinary AWTRIX-compatible JSON wherever possible. That keeps the
remote protocol useful even if its transport changes later and lets AgentClock eventually publish
through the same service.

### Firmware-fork boundaries

Keep the fork easy to rebase:

- isolate remote-control code in its own module;
- make it opt-in and disabled by default;
- keep configuration separate from normal AWTRIX settings where practical;
- make the polling client call existing public/internal display APIs;
- avoid modifying the renderer, app loop, Wi-Fi manager, and updater unless strictly necessary;
- document the exact upstream commit/tag used for every build.

Before choosing a TLS/MQTT library or memory budget, inspect the then-current AWTRIX-NG source and
measure free heap on the physical clock. Do not assume today's dependencies or partition layout will
still apply when this project resumes.

### Resume checklist

Revisit this project when all of the following are true:

1. AWTRIX-NG releases and its networking/configuration interfaces have been reasonably stable for a
   while, and a specific upstream tag is selected as the fork base.
2. The display can be recovered reliably with the official flasher if a development build fails.
3. Current firmware licensing and contribution requirements have been reviewed.
4. Free flash, RAM, TLS handshake cost, and polling power/network impact have been measured.
5. A small hosting target and expected ongoing cost have been chosen.
6. The authentication, token-provisioning, rotation, and recovery experience has been designed.
7. Time has been reserved for upstream rebases, security patches, device testing, and documentation.

Until then, keep using AgentClock over the local network. A Tailscale subnet router or a small local
relay remains the no-fork fallback if remote access becomes urgent before the firmware is ready.
