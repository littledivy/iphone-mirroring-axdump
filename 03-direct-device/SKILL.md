---
name: control-iphone-direct
description: Read and control the user's iPhone directly over the developer connection (USB or Wi-Fi) via the device's own accessibility audit daemon. No iPhone Mirroring, no VoiceOver, no SIP changes. Use when asked to read the iPhone screen, find something on it, or operate it.
---

# Control iPhone directly (developer connection)

Talks to `com.apple.accessibility.axAuditDaemon` on the phone — the same service
Xcode's Accessibility Inspector uses. Gives real element captions, states, and
element ids; can press elements and run audits. Stock macOS, no entitlement
hacks.

## Preconditions

1. One-time setup: `./setup.sh` (creates an OpenSSL Python 3.13 venv, installs
   pymobiledevice3, applies the RSDCheckin fix needed for wireless).
2. Tunnel daemon running (root):
   `sudo .venv/bin/pymobiledevice3 remote tunneld --protocol tcp`
   - USB works out of the box.
   - Wi-Fi: enable once over USB with
     `.venv/bin/pymobiledevice3 lockdown wifi-connections --state on`, then the
     daemon builds a Wi-Fi tunnel.
3. Device paired + Developer Mode on. Phone **unlocked and awake** to see app
   content (a locked phone only exposes the lock screen).

## Commands

```
python device_axtree.py read           # JSON: [{caption, spoken, id}, ...] for the current screen
python device_axtree.py tap "<substr>" # press first element whose caption contains substr
python device_axtree.py audit          # on-device accessibility audit
```

## How to operate

- `read` first; decide the next action; act; `read` again to confirm. The tree
  reflects the **current screen only** — `iter_elements` walks the focusable
  elements of the foreground app/page, not the whole device.
- Unread counts are on the app-icon captions on the home screen
  (e.g. `"Telegram, 14 new items"`) — you can read them without opening the app.

## Known limits (measured)

- **Reading is reliable** over USB and Wi-Fi.
- **Launching apps is weak**: `perform_press` from SpringBoard needs
  `task_for_pid-allow` (SpringBoard lacks it), and `dvt launch` can drop over the
  wireless tunnel. `tap` works well *inside* an already-open app; to open an app,
  prefer having the user (or a reliable launcher) foreground it, then read.
- The target must be on the **currently visible** screen for `tap` to find it;
  navigate/scroll to it first.

## Safety

Operating the user's real phone. Do not send messages, make calls, purchase, or
delete unless explicitly asked. Reading is safe.
