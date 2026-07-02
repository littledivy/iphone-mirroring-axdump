#!/usr/bin/env python3
"""Read and drive the iPhone accessibility tree directly over the developer
connection (no iPhone Mirroring, no VoiceOver, no SIP).

Requires a running tunnel daemon (see setup.sh) and the RSDCheckin fix applied
for wireless. Run with the venv Python created by setup.sh.

    python device_axtree.py read              # current-screen elements as JSON
    python device_axtree.py tap "<substr>"    # press first element whose caption matches
    python device_axtree.py audit             # run the on-device accessibility audit
"""
import asyncio
import json
import sys
import warnings

warnings.filterwarnings("ignore")

from pymobiledevice3.tunneld.api import get_tunneld_devices
from pymobiledevice3.services.accessibilityaudit import AccessibilityAudit


async def _rsd():
    devs = await get_tunneld_devices()
    if not devs:
        raise SystemExit("no device via tunneld — is `pymobiledevice3 remote tunneld` running?")
    return devs[0]


async def read(limit: int = 200):
    rsd = await _rsd()
    out = []
    async with AccessibilityAudit(rsd) as ax:
        i = 0
        async for el in ax.iter_elements():
            out.append({
                "caption": (el.caption or "").strip(),
                "spoken": (el.spoken_description or "").strip(),
                "id": el.platform_identifier,
            })
            i += 1
            if i >= limit:
                break
    print(json.dumps(out, ensure_ascii=False, indent=2))


async def tap(substr: str):
    rsd = await _rsd()
    async with AccessibilityAudit(rsd) as ax:
        i = 0
        async for el in ax.iter_elements():
            cap = (el.caption or "").replace("‎", "").strip()
            i += 1
            if substr.lower() in cap.lower():
                await ax.perform_press(el.element.identifier)
                print(f"tapped: {cap}")
                return
            if i > 300:
                break
    raise SystemExit(f'no element matching "{substr}" on the current screen '
                     f'(navigate to it first — iter only sees the visible screen)')


async def audit():
    rsd = await _rsd()
    async with AccessibilityAudit(rsd) as ax:
        types = await ax.supported_audits_types()
        issues = await ax.run_audit(types)
        print(json.dumps([str(x) for x in issues], ensure_ascii=False, indent=2))


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "read"
    if cmd == "read":
        asyncio.run(read())
    elif cmd == "tap":
        if len(args) < 2:
            raise SystemExit('usage: tap "<caption substring>"')
        asyncio.run(tap(args[1]))
    elif cmd == "audit":
        asyncio.run(audit())
    else:
        raise SystemExit(f"unknown command: {cmd}\nvalid: read tap audit")


if __name__ == "__main__":
    main()
