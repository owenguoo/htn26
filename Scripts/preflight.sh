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

echo "=== swift test toolchain ==="
if DEVELOPER_DIR=/Library/Developer/CommandLineTools swift --version >/dev/null 2>&1; then
  echo "  ok: Command Line Tools toolchain works; swift test needs nothing else"
else
  echo "  MISSING: no usable Swift toolchain"
  status=1
fi

exit $status
