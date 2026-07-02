# 02 — Mirroring AX (Swift, become the assistive client)

Instead of passively sniffing (see `../01-dtrace-sniffer`), attach to iPhone
Mirroring as the assistive client ourselves and read/drive its tree with the
public `AXUIElement` API.

```
./build.sh              # compile + sign remote_axtree.swift with entitlements
./remote_axtree read    # text tree of the current screen
./remote_axtree json    # id, role, label, x/y/w/h, actions
./remote_axtree tap "Messages"
./remote_axtree home | apps | swipe up | type "hi"
```

## How it works

iPhone Mirroring loads Apple's `AccessibilityPlatformTranslation` (`AXPTranslator`)
inside its own process, wired to the Continuity link. That translator exposes the
iOS UI as macOS AX elements, but only to a client holding the private
`com.apple.private.accessibility.remoteDeviceContent` entitlement (this is what
VoiceOver has). `remote_axtree` carries that entitlement, sets
`AXEnhancedUserInterface` on the app/window/hosting-view to flip the translator
on, then reads via `AXUIElement` and acts via `AXPress`/`CGEvent`.

## The catch — this needs a weakened Mac

The entitlement is `com.apple.private.*`; AMFI only honors it on Apple-signed
code. To use a self-signed copy you must:

- **SIP disabled** (`csrutil status` → disabled), and
- **AMFI relaxed** (`sudo nvram boot-args="amfi_get_out_of_my_way=0x1"`).

On a stock Mac the entitlement is ignored and you see only the Mac window chrome,
not iOS content. So this is a dev-box tool. We verified the mechanism end to end
(read + tap + navigate), including that the capability is inherited from the
process audit token — but there is no way to get it honored on stock macOS
without disabling SIP/AMFI (which is Apple's designed boundary, not a bug).

For a stock-macOS path that needs none of this, use `../03-direct-device`.
