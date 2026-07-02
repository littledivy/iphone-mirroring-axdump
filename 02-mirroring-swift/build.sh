#!/bin/bash
# Build and sign remote_axtree.
#
# Requires (one-time, machine-level) for the private entitlement to be honored:
#   - System Integrity Protection disabled     (csrutil status  -> disabled)
#   - AMFI relaxed: boot-args amfi_get_out_of_my_way=0x1
#       sudo nvram boot-args="amfi_get_out_of_my_way=0x1"   (then reboot)
# On a stock Mac (SIP on) the OS rejects the self-signed entitlement and the
# iOS tree will NOT appear (you'll only see the Mac window chrome).
#
# Also grant Accessibility permission to the terminal you run this from:
#   System Settings > Privacy & Security > Accessibility
set -euo pipefail
cd "$(dirname "$0")"

echo "checking machine prerequisites..."
csrutil status 2>/dev/null | grep -qi disabled || echo "  WARNING: SIP is not disabled — entitlement will be ignored."
nvram boot-args 2>/dev/null | grep -qi "amfi_get_out_of_my_way" || echo "  WARNING: amfi_get_out_of_my_way not set — entitlement may be ignored."

echo "compiling..."
swiftc -O remote_axtree.swift -o remote_axtree

echo "signing with entitlements..."
codesign -s - --entitlements entitlements.plist -f remote_axtree

echo "verifying entitlements..."
codesign -d --entitlements - remote_axtree 2>/dev/null | grep -i remoteDeviceContent >/dev/null \
  && echo "  ok: remoteDeviceContent present" || { echo "  FAILED to embed entitlement"; exit 1; }

echo "done -> ./remote_axtree"
