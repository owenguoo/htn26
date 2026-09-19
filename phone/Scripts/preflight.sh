#!/usr/bin/env bash
# Checks the two things about this machine that Scripts/verify.sh cannot fix.
set -uo pipefail

status=0

echo "=== Xcode license ==="
if xcodebuild -version >/dev/null 2>&1 && xcodebuild -showsdks >/dev/null 2>&1; then
  echo "  ok: accepted"
else
  echo "  MISSING. Until this is accepted, every swift, xcrun and xcodebuild"
  echo "  invocation under Xcode refuses. Run:"
  echo "      sudo xcodebuild -license accept"
  status=1
fi

echo "=== iOS Simulator runtime ==="
# Directory existence is not enough: those appear as soon as a download starts.
# The only thing that means anything is simctl listing a bootable device.
if xcrun simctl list devices available 2>/dev/null | grep -qi "iPhone"; then
  echo "  ok: a runtime is installed"
  xcrun simctl list devices available 2>/dev/null | grep -i "iPhone 16" | head -3
elif xcrun simctl list runtimes 2>/dev/null | grep -qi "iOS"; then
  echo "  PARTIAL: a runtime is installed but no iPhone device exists yet. Run:"
  echo "      xcrun simctl create 'iPhone 16' 'iPhone 16'"
  status=1
else
  echo "  MISSING. This Xcode does not ship the iOS Simulator runtime, so there"
  echo "  are no simulator devices and -destination cannot resolve. Run:"
  echo "      xcodebuild -downloadPlatform iOS"
  echo "  (multi-gigabyte download)"
  status=1
fi

echo "=== the destination the gate names ==="
# The runtime ships device types, not devices. iOS 26.3 creates an iPhone 16e
# and a few 17s but no plain iPhone 16, which is the name Scripts/verify.sh
# uses — so it has to be created once.
if xcrun simctl list devices available 2>/dev/null | grep -q "iPhone 16 ("; then
  echo "  ok: an 'iPhone 16' device exists"
elif xcrun simctl list devicetypes 2>/dev/null | grep -q "SimDeviceType.iPhone-16$"; then
  echo "  MISSING, but the device type is available. Run:"
  echo "      xcrun simctl create 'iPhone 16' com.apple.CoreSimulator.SimDeviceType.iPhone-16"
  status=1
else
  echo "  MISSING, and this runtime has no iPhone 16 device type. Point"
  echo "  Scripts/verify.sh at a name from: xcrun simctl list devices available"
  status=1
fi

echo "=== swift test toolchain ==="
if DEVELOPER_DIR=/Library/Developer/CommandLineTools swift --version >/dev/null 2>&1; then
  echo "  ok: Command Line Tools toolchain works; swift test needs nothing else"
else
  echo "  MISSING: no usable Swift toolchain"
  status=1
fi

exit $status
