# iphone-mirroring-axdump

Getting the **iOS accessibility tree** onto a Mac — to build tools for low-vision
users or to drive an iPhone from an agent. Three approaches, in the order they
were discovered, worst → best:

| # | Approach | Reads iOS tree | Control | Stock Mac? | Needs |
|---|----------|:---:|:---:|:---:|-------|
| [01](01-dtrace-sniffer) | dtrace-sniff iPhone Mirroring | passive only | no | needs `sudo` | VoiceOver running |
| [02](02-mirroring-swift) | Be Mirroring's AX client (Swift) | yes | yes | **no** | SIP off + AMFI off |
| [03](03-direct-device) | Talk to the phone directly | **yes** | read≫launch | **yes** | dev connection + tunnel |

## TL;DR

- **[01 — dtrace sniffer](01-dtrace-sniffer)** — the original: hook
  `AXPMacPlatformElement` in the Mirror process, rebuild the tree from what
  VoiceOver queries. Passive (no VoiceOver ⇒ no data), `sudo`, fragile. History.

- **[02 — Mirroring AX (Swift)](02-mirroring-swift)** — attach to iPhone
  Mirroring as the assistive client and read/drive its tree via `AXUIElement`.
  Works fully (read + tap + navigate) but the remote content is gated by the
  private `remoteDeviceContent` entitlement, which AMFI only honors with **SIP +
  AMFI disabled**. Dev-box only. We chased the entitlement wall to the metal
  (disassembled the HIServices check, proved the capability is inherited from the
  process audit token) — there is no stock-Mac bypass short of defeating SIP.

- **[03 — Direct device](03-direct-device)** — the good one. Skip Mirroring; talk
  to the phone's own `axAuditDaemon` over the developer connection (like Xcode's
  Accessibility Inspector), via [pymobiledevice3]. **Stock macOS, no VoiceOver, no
  SIP, no entitlement.** Works over USB and — after a one-line-ish pymobiledevice3
  fix (`RSDCheckin` for RSD DTX shims, see
  [`pymobiledevice3-rsdcheckin.patch`](03-direct-device/pymobiledevice3-rsdcheckin.patch))
  — over **Wi-Fi**. Reading is rock solid; app-launching is the weak spot.

See [`APPLE_FEEDBACK.md`](APPLE_FEEDBACK.md) for the (non-security) Feedback
Assistant notes: an enhancement request for a supported third-party path, and a
low-severity hardening note.

[pymobiledevice3]: https://github.com/doronz88/pymobiledevice3
