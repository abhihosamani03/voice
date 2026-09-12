#!/usr/bin/env bash
# ── iTantra two-phone BLE mesh verification ────────────────────────────
# Automates: install → grant permissions → launch → capture logs on TWO
# physical phones, then checks logcat for the mesh handshake evidence.
#
# Prerequisites:
#   • Both phones connected via USB with USB debugging enabled
#   • Bluetooth + Location ON on both phones, phones within a few meters
#   • APK built: flutter build apk --release --split-per-abi
#
# Usage:
#   bash scripts/verify_mesh.sh                 # auto-detect 2 devices
#   bash scripts/verify_mesh.sh <SERIAL1> <SERIAL2>

set -uo pipefail

ADB="${ADB:-$HOME/AppData/Local/Android/Sdk/platform-tools/adb.exe}"
APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
PKG="com.example.voice"
LOG_WINDOW=45   # seconds to capture logs after launch

# ── pick two devices ───────────────────────────────────────────────────
mapfile -t DEVS < <("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')
if [ "${#@}" -ge 2 ]; then
  DEVS=("$1" "$2")
elif [ "${#DEVS[@]}" -lt 2 ]; then
  echo "ERROR: need two USB-connected phones (found: ${#DEVS[@]})."
  "$ADB" devices
  exit 1
fi
D1="${DEVS[0]}"; D2="${DEVS[1]}"
echo "Phones: $D1 (trekker/sender) + $D2 (ranger/receiver)"

# ── helper: run a command on one phone ────────────────────────────────
run_on() { # $1=serial, $2=command...
  local s="$1"; shift
  "$ADB" -s "$s" "$@"
}

# ── 0. fresh install on both ──────────────────────────────────────────
for s in "$D1" "$D2"; do
  echo "── [$s] uninstalling old build (if any)…"
  run_on "$s" uninstall "$PKG" >/dev/null 2>&1
  echo "── [$s] installing $APK…"
  if [[ "$APK" == *arm64* ]]; then
    run_on "$s" install -r --abi arm64-v8a "$APK" || { echo "install failed on $s"; exit 1; }
  else
    run_on "$s" install -r "$APK" || { echo "install failed on $s"; exit 1; }
  fi
  echo "── [$s] granting runtime permissions…"
  for p in \
    android.permission.RECORD_AUDIO \
    android.permission.ACCESS_FINE_LOCATION \
    android.permission.ACCESS_COARSE_LOCATION \
    android.permission.BLUETOOTH_SCAN \
    android.permission.BLUETOOTH_CONNECT \
    android.permission.BLUETOOTH_ADVERTISE \
    android.permission.MODIFY_AUDIO_SETTINGS; do
    run_on "$s" shell pm grant "$PKG" "$p" 2>/dev/null
  done
  echo "── [$s] enabling GPS…"
  run_on "$s" shell settings put secure location_mode 3 2>/dev/null
  run_on "$s" shell settings put global ble_scan_always_enabled 1 2>/dev/null
done

# ── 1. clear logcat + launch on both ─────────────────────────────────
for s in "$D1" "$D2"; do
  run_on "$s" logcat -c
  echo "── [$s] launching iTantra…"
  run_on "$s" shell am start -n "$PKG/.MainActivity" >/dev/null
done

# ── 2. capture logs while mesh starts ────────────────────────────────
echo ""
echo "Capture window: ${LOG_WINDOW}s — the toggle-ON step below is MANUAL."
echo "  → On BOTH phones: flip the transceiver switch ON (top right)."
echo "  → Models download on first run (needs internet once, ~200 MB)."
echo ""
sleep "$LOG_WINDOW"

# ── 3. collect + analyse logs ─────────────────────────────────────────
mkdir -p build/mesh-verify
for s in "$D1" "$D2"; do
  run_on "$s" logcat -d > "build/mesh-verify/$s.log" 2>/dev/null
done

echo "════════ ANALYSIS ════════"
fail=0
for s in "$D1" "$D2"; do
  log="build/mesh-verify/$s.log"
  echo "── Phone $s"
  if grep -q "BleMesh: started (advertising + scanning)" "$log"; then
    echo "   ✅ BLE mesh started (advertising + scanning)"
  else
    echo "   ❌ mesh did NOT start — look for the failure reason:"
    grep -E "BleMesh: (central authorize|peripheral authorize|BLE unsupported|permissions|powered|state did not)" "$log" | tail -3
    fail=1
  fi
  peers=$(grep -c "BleMesh: discovered iTantra peer" "$log" || true)
  echo "   ℹ️  peers discovered so far: $peers"
done

echo ""
if [ "$fail" -eq 0 ]; then
  echo "PASS on radio bring-up. For the full relay test:"
  echo "  1. Keep both phones close (1–5 m), Bluetooth ON, app open."
  echo "  2. Phone A: hold PTT, speak in the sender language, release."
  echo "  3. Watch phone B: text should appear and be spoken aloud."
  echo "  → 'discovered iTantra peer' in the logs proves mesh discovery."
else
  echo "CHECK FAILED — see the failure reasons above and build/mesh-verify/*.log"
fi
exit $fail
