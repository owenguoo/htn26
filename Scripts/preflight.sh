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
if [ -d /Library/Developer/CoreSimulator/Profiles/Runtimes ] \
   || [ -d /Library/Developer/CoreSimulator/Volumes ]; then
  echo "  ok: a runtime is installed"
  xcrun simctl list devices available 2>/dev/null | grep -i "iPhone 16" | head -3
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
