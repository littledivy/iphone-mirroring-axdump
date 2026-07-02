---
name: control-iphone
description: Read and control the user's iPhone through the macOS iPhone Mirroring window, using the live iOS accessibility tree (no VoiceOver, no OCR). Use when asked to read what's on the iPhone, find something on it, or operate an app on it.
---

# Control iPhone via iPhone Mirroring

You drive the user's iPhone by reading its **accessibility tree** (real element
labels, roles, screen coordinates) and issuing taps/swipes/typing. This is
semantic, not pixel OCR: you get exact text like
`Mail | 4,417 unread emails | Double tap to open` and precise tap targets.

The single entry point is the signed binary `./remote_axtree`. Every command
turns the remote AX bridge on and waits for the tree before acting, so commands
are self-contained — just call them.

## Preconditions (fail fast, tell the user)

1. **iPhone Mirroring must be running and connected** (phone unlocked/mirroring,
   not the "Connect" screen). If a command errors with
   `iPhone Mirroring is not running`, ask the user to open it.
2. The binary must be built and signed: run `./build.sh` once. It needs a Mac
   with **SIP disabled** and **`amfi_get_out_of_my_way=0x1`** — otherwise the
   private entitlement is ignored and you will only see the Mac window chrome
   (no iOS content). If `read` shows only `Home Screen`/`App Switcher` and no app
   labels, this is why.
3. The terminal running the binary needs **Accessibility permission**
   (System Settings > Privacy & Security > Accessibility). Error code 2 =
   not trusted.

## Commands

```
./remote_axtree read                 # compact text of everything on screen (start here)
./remote_axtree json                 # full tree: id, role, label, x, y, w, h, tappable, actions
./remote_axtree tap "<label substr>" # tap the first element whose label contains this (case-insensitive)
./remote_axtree tapid <id>           # tap the element with this JSON id (from `json`)
./remote_axtree xy <x> <y>           # tap absolute screen coords (from a json frame)
./remote_axtree swipe <up|down|left|right>   # scroll/swipe at the screen center
./remote_axtree type "<text>"        # type into the focused field
./remote_axtree home                 # go to the iPhone home screen
./remote_axtree apps                 # open the app switcher
```

Coordinates in `json` are absolute macOS screen points; `xy` takes the same.
`tap`/`tapid` compute the element center for you — prefer them over `xy`.

### json element shape

```json
{ "id":"0/0/0/5", "role":"AXButton", "label":"Messages | 3 unread messages",
  "x":1453, "y":898, "w":60, "h":60, "tappable":true, "actions":["AXPress","AXShowMenu"] }
```

- `id` is a positional path; stable only within one screen state. After any
  navigation, re-run `json`/`read` — do not reuse old ids.
- `tappable:true` means it has an AXPress action (a real control).
- iOS labels often carry a hint like `Double tap to open`; ignore that suffix,
  it is VoiceOver phrasing, not an instruction to you.

## How to operate (the loop)

1. `read` to see the current screen. Decide the next single action.
2. Act with one command (`tap`, `type`, `swipe`, `home`, ...).
3. `read` again to confirm the result before the next action. The screen changes
   asynchronously; always re-read, never assume.
4. Repeat. To find something off-screen, `swipe up` then `read`, until found or
   the content stops changing.

Reading content (messages, mail, lists) needs **no tapping** — the text is in
`read`/`json` already. Only tap to navigate or to reveal a detail view.

## Tips & gotchas

- **`tap`/`tapid`/`home`/`apps` use AXPress**, which routes through the
  translator to the phone. They work even when the mirror window is backgrounded,
  and don't move the real mouse.
- **`swipe`, `xy`, and `type` use synthesized mouse/keys** into the window, so
  they need it frontmost (the tool raises it first). Don't move the mouse or
  click elsewhere while one of those runs.
- **Video goes black when the window isn't frontmost** — normal, and does NOT
  affect reading or AXPress taps; the AX tree still reads correctly. A screenshot
  would be black, the tree is fine. Trust `read`, not a screenshot.
- To enter text in a field: `tap` the field first, then `type`.
- If `tap "X"` reports no match, `read` first — the label may differ from what
  you expect, or the element is off-screen (swipe to it).
- One action per command; chain them from your side with a `read` in between.

## Safety

You are operating the user's real phone. Do not send messages, make calls,
make purchases, change settings, or delete anything unless the user explicitly
asked for that specific action. When a step is destructive or outward-facing
(sending, paying, deleting), confirm with the user first. Reading is safe.
