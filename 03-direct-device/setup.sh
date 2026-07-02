#!/bin/bash
# Set up the direct-device accessibility path.
#
# Talks to the iPhone's own accessibility audit daemon over the developer
# connection (the same service Xcode's Accessibility Inspector uses). No iPhone
# Mirroring, no VoiceOver, no SIP/AMFI changes. Stock macOS.
#
# Requirements:
#   - Xcode / a modern toolchain, and `uv` (https://astral.sh) for a Python that
#     ships OpenSSL (macOS system Python is LibreSSL and cannot do the PSK
#     ciphers the iOS 18.2+ TCP tunnel needs).
#   - Device paired + Developer Mode enabled.
set -euo pipefail
cd "$(dirname "$0")"

VENV="${VENV:-$PWD/.venv}"

echo "== creating Python 3.13 (OpenSSL) venv via uv =="
uv venv --python 3.13 "$VENV"
uv pip install --python "$VENV/bin/python" pymobiledevice3

echo "== applying RSDCheckin fix (wireless accessibility over RSD) =="
"$VENV/bin/python" - "$VENV" <<'PY'
import sys, pathlib
venv = pathlib.Path(sys.argv[1])
f = next(venv.glob("lib/python*/site-packages/pymobiledevice3/dtx_service_provider.py"))
s = f.read_text()
orig = ('        lockdown = self.lockdown\n'
        '        attr = await lockdown.get_service_connection_attributes(service_name, False)\n')
fix = ('        lockdown = self.lockdown\n'
       '        # RSDCheckin fix: lockdown-style RSD services (UsesRemoteXPC=False,\n'
       '        # e.g. *.shim.remote DTX daemons like axAuditDaemon) require the\n'
       '        # RSDCheckin handshake before accepting DTX framing; a raw TCP\n'
       '        # connect is dropped by iOS 26. start_lockdown_service does RSDCheckin.\n'
       '        if isinstance(lockdown, RemoteServiceDiscoveryService):\n'
       '            svc = await lockdown.start_lockdown_service(service_name)\n'
       '            return DTXConnection(svc.reader, svc.writer)\n'
       '        attr = await lockdown.get_service_connection_attributes(service_name, False)\n')
if fix.strip() in s:
    print("  already patched")
elif orig in s:
    f.write_text(s.replace(orig, fix)); print("  patched", f)
else:
    print("  WARNING: anchor not found — pymobiledevice3 layout changed; patch by hand from pymobiledevice3-rsdcheckin.patch"); sys.exit(1)
PY

cat <<EOF

== next steps ==
1) Start the tunnel daemon (root; keep it running):
     sudo "$VENV/bin/pymobiledevice3" remote tunneld --protocol tcp
   (USB or Wi-Fi. For Wi-Fi, first enable it once over USB:
     "$VENV/bin/pymobiledevice3" lockdown wifi-connections --state on )
2) Read the tree / drive the phone:
     "$VENV/bin/python" device_axtree.py read
     "$VENV/bin/python" device_axtree.py tap "WhatsApp"
EOF
