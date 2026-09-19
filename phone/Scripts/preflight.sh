#!/usr/bin/env bash
# Checks the things about this machine that Scripts/verify.sh cannot fix.
set -uo pipefail

status=0
IOS_SIMULATOR_OS="${IOS_SIMULATOR_OS:-26.3.1}"
IOS_SIMULATOR_RUNTIME_VERSION="${IOS_SIMULATOR_RUNTIME_VERSION:-26.3}"
IOS_SIMULATOR_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-3"

echo "=== Xcode license ==="
if xcodebuild -version >/dev/null 2>&1 && xcodebuild -showsdks >/dev/null 2>&1; then
  echo "  ok: accepted"
else
  echo "  MISSING. Until this is accepted, every swift, xcrun and xcodebuild"
  echo "  invocation under Xcode refuses. Run:"
  echo "      sudo xcodebuild -license accept"
  status=1
fi

echo "=== iOS $IOS_SIMULATOR_RUNTIME_VERSION Simulator runtime ==="
# Directory existence is not enough: those appear as soon as a download starts.
# The only thing that means anything is simctl listing a bootable device.
if xcrun simctl list runtimes 2>/dev/null | grep -q "iOS $IOS_SIMULATOR_RUNTIME_VERSION "; then
  echo "  ok: iOS $IOS_SIMULATOR_RUNTIME_VERSION is installed"
elif xcrun simctl list runtimes 2>/dev/null | grep -qi "iOS"; then
  echo "  WRONG VERSION: an iOS runtime is installed, but not $IOS_SIMULATOR_RUNTIME_VERSION."
  echo "  Install the iOS $IOS_SIMULATOR_RUNTIME_VERSION runtime in Xcode Settings → Components."
  status=1
else
  echo "  MISSING. This Xcode does not have the iOS $IOS_SIMULATOR_RUNTIME_VERSION runtime, so there"
  echo "  are no simulator devices and -destination cannot resolve. Run:"
  echo "      xcodebuild -downloadPlatform iOS"
  echo "  (multi-gigabyte download)"
  status=1
fi

echo "=== the destination the gate names ==="
# The runtime ships device types, not devices. iOS 26.3 creates an iPhone 16e
# and a few 17s but no plain iPhone 16, which is the name Scripts/verify.sh
# uses — so it has to be created once.
if xcrun simctl list devices available 2>/dev/null | awk -v os="$IOS_SIMULATOR_RUNTIME_VERSION" '
    $0 == "-- iOS " os " --" { in_runtime = 1; next }
    /^-- / { in_runtime = 0 }
    in_runtime && /iPhone 16 \(/ { found = 1 }
    END { exit !found }
  '; then
  echo "  ok: an iPhone 16 exists on iOS $IOS_SIMULATOR_RUNTIME_VERSION"
elif xcrun simctl list devicetypes 2>/dev/null | grep -q "SimDeviceType.iPhone-16$"; then
  echo "  MISSING, but the device type is available. Run:"
  echo "      xcrun simctl create 'iPhone 16' com.apple.CoreSimulator.SimDeviceType.iPhone-16 $IOS_SIMULATOR_RUNTIME"
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

echo "=== Xcode version for Expo SDK 57 ==="
# SDK 57 (RN 0.86) needs Xcode >= 26.4. SwarmCore and the hub e2e do not.
xcode_version=$(xcodebuild -version 2>/dev/null | awk '/^Xcode/ {print $2}')
if [ -n "$xcode_version" ] && [ "$(printf '%s\n26.4\n' "$xcode_version" | sort -V | head -1)" = "26.4" ]; then
  echo "  ok: Xcode $xcode_version"
else
  echo "  TOO OLD: Xcode ${xcode_version:-none}; the Expo app needs >= 26.4."
  echo "  Update from the App Store or developer.apple.com/download."
  # Fatal only for the Expo app. `--core` (what verify.sh passes) checks just
  # what SwarmCore, the Swift shell and the hub e2e need.
  if [ "${1:-}" != "--core" ]; then status=1; fi
fi

echo "=== node and pnpm ==="
if node -v 2>/dev/null | grep -q '^v22\.'; then
  echo "  ok: node $(node -v)"
else
  echo "  MISSING: Node 22 LTS (found: $(node -v 2>/dev/null || echo none)). Run: nvm install 22"
  status=1
fi
if command -v pnpm >/dev/null 2>&1; then
  echo "  ok: pnpm $(pnpm -v)"
else
  echo "  MISSING: pnpm. Run: corepack enable pnpm"
  status=1
fi

echo "=== hub toolchain ==="
# The hub lives at the repo root, one level above phone/.
if command -v uv >/dev/null 2>&1; then
  echo "  ok: $(uv --version)"
  if (cd "$(dirname "$0")/../.." && uv run --frozen python -c 'import swarm.hub' >/dev/null 2>&1); then
    echo "  ok: swarm.hub imports"
  else
    echo "  MISSING: hub dependencies. Run from the repo root: uv sync"
    status=1
  fi
else
  echo "  MISSING: uv. Run: brew install uv"
  status=1
fi

exit $status
