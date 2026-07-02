# Apple Feedback drafts

Two items for **Feedback Assistant** (feedbackassistant.apple.com). Neither is a
security vulnerability — on a stock Mac (SIP + AMFI enabled) the accessibility
entitlement boundary held in every test. Do **not** file these as an Apple
Security Bounty / product-security report; there is no bypass. Reading the
mirrored tree only exposes what is already on screen, and the only way to read it
required the user to disable SIP + AMFI first (documented, intended behavior).

---

## Item 1 — Enhancement request

**Title:** Supported way for assistive technologies to read the iPhone Mirroring
accessibility tree

**Component:** Accessibility

**Type:** Suggestion / enhancement

**Description:**
iPhone Mirroring exposes the mirrored device's accessibility tree via
`AccessibilityPlatformTranslation` (`AXPTranslator`) inside the Mirror process.
Only clients holding the private entitlement
`com.apple.private.accessibility.remoteDeviceContent` (checked per AX connection
via the caller's audit token in HIServices) can read the remote elements —
today that is effectively just VoiceOver.

Third-party developers building assistive / low-vision tools (custom screen
readers, automation for motor-impaired users, alternative navigation) have no
supported way to read this tree. A normal AX client with the user-granted
Accessibility (TCC) permission sees only the Mac window chrome; the entire
mirrored surface is an opaque `AXHostingView` of pixels.

**Request:** a supported mechanism for approved assistive apps to read the
iPhone Mirroring remote accessibility tree — e.g. a managed/requestable
entitlement (similar to other restricted capabilities granted via provisioning),
or a public API gated by the user's Accessibility permission plus consent.

**Impact:** enables an ecosystem of third-party accessibility tools for
iPhone-via-Mac, instead of pixel OCR workarounds that lose semantic data
(labels, states, offscreen text).

---

## Item 2 — Security hardening (defense-in-depth, low severity)

**Title:** Accessibility helpers holding `remoteDeviceContent` are signed without
hardened runtime / library validation

**Component:** Security / Code Signing

**Type:** Suggestion (defense-in-depth)

**Severity:** Low — not exploitable on a stock system (SIP prevents task-port
access to these platform binaries, and restricted-entitlement env stripping
blocks `DYLD_INSERT_LIBRARIES`). Relevant only as hardening if SIP is disabled or
in a compromised state.

**Description:**
The binaries below hold the powerful private entitlement
`com.apple.private.accessibility.remoteDeviceContent` yet are code-signed with
`flags=0x0` (no hardened runtime `CS_RUNTIME`, no library-validation
`CS_REQUIRE_LV`):

- `/System/Library/CoreServices/VoiceOver.app/Contents/MacOS/VoiceOver`
- `/System/Library/CoreServices/VoiceOver.app/Contents/MacOS/VoiceOverStarter`
- `/System/Library/CoreServices/KeyboardAccessAgent.app/Contents/MacOS/KeyboardAccessAgent`
- `/System/Library/CoreServices/Dwell Control.app/Contents/MacOS/Dwell Control`

Because the remote-AX capability is inherited from the process's audit token, any
code running inside one of these processes gains the capability regardless of its
own signature. Enabling hardened runtime + library validation on these entitled
helpers would raise the bar for code injection into them (e.g. if SIP is off),
consistent with how other sensitive entitled system binaries are signed.

**Repro / observation:**
```
codesign -dv /System/Library/CoreServices/VoiceOver.app/Contents/MacOS/VoiceOver
# CodeDirectory ... flags=0x0(none)
codesign -d --entitlements - <binary> | grep remoteDeviceContent
```

**Suggested fix:** sign these entitled accessibility helpers with hardened
runtime and library validation enabled.
