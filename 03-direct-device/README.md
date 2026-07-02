# 03 — Direct device (the good one)

Skip iPhone Mirroring entirely. Talk to the phone's **own** accessibility audit
daemon (`com.apple.accessibility.axAuditDaemon`) over the developer connection —
the same service Xcode's Accessibility Inspector uses. **Stock macOS: no
Mirroring, no VoiceOver, no SIP/AMFI changes, no private entitlement.**

```
./setup.sh                                  # OpenSSL py3.13 venv + pymobiledevice3 + the fix
sudo .venv/bin/pymobiledevice3 remote tunneld --protocol tcp   # keep running
.venv/bin/python device_axtree.py read      # current-screen elements as JSON
.venv/bin/python device_axtree.py tap "WhatsApp"
.venv/bin/python device_axtree.py audit
```

Built on [pymobiledevice3]. Works over USB out of the box; for Wi-Fi enable it
once over USB (`lockdown wifi-connections --state on`).

## The wireless fix (`pymobiledevice3-rsdcheckin.patch`)

Over USB this worked immediately. Over the wireless RemoteXPC tunnel the
accessibility service died with *"Connection was terminated abruptly"* while
`dvt`/`lockdown` worked fine. Root cause: `DtxServiceProvider` opens RSD DTX
services with a raw TCP connect and skips the `RSDCheckin` handshake. That's fine
for RemoteXPC-native DTX (`dtservicehub`) but lockdown-style shims advertised over
RSD with `UsesRemoteXPC=False` — like
`com.apple.accessibility.axAuditDaemon.remoteserver.shim.remote` — require
`RSDCheckin` first, so iOS 26 dropped the connection on the first DTX byte.

Fix: for `RemoteServiceDiscoveryService`, use `start_lockdown_service` (which
performs `RSDCheckin`) instead of a raw `create_service_connection`. `setup.sh`
applies it; `pymobiledevice3-rsdcheckin.patch` documents it. Worth upstreaming.

## Verified

- Read the live tree over **USB and Wi-Fi** (home-screen unread badges:
  `Messages 3`, `Slack 8`, `Ola 9`, `Telegram 14`, …).
- Full API present: `iter_elements`, `run_audit`, `move_focus`, `perform_press`,
  element rects.

## Limits

- Reading is reliable. **Launching apps is weak**: `perform_press` from
  SpringBoard needs `task_for_pid-allow` (SpringBoard lacks it); `dvt launch` can
  drop over the tunnel. `tap` is reliable *inside* an already-open app.
- The phone must be **unlocked and awake** for app content; locked ⇒ lock screen
  only.
- `tap`/`read` see the **current screen** only; navigate to the target first.

[pymobiledevice3]: https://github.com/doronz88/pymobiledevice3
