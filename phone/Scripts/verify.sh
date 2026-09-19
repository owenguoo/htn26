#!/usr/bin/env bash
# The only two commands that count as evidence.
#
# CLAUDE.md: "You cannot run ARKit. It does not exist in the iOS Simulator. Do
# not write code you cannot test, and never claim positioning works."
#
# So: swift test proves the logic, xcodebuild proves the app compiles, and
# DEVICE_CHECKLIST.md covers everything neither can touch.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== gate 1/2: swift test ==="
(cd Packages/SwarmCore && swift test)

echo
echo "=== gate 2/2: xcodebuild, iOS Simulator ==="
# This gate needs an accepted Xcode license and an installed iOS Simulator
# runtime. Scripts/preflight.sh says which, if either, is missing.
Scripts/preflight.sh --core >/dev/null 2>&1 || {
  echo
  echo "the machine is not set up for this gate:"
  Scripts/preflight.sh --core
  exit 1
}
xcodebuild -scheme Beacon -destination 'platform=iOS Simulator,name=iPhone 16' build

echo
echo "=== expo shell: typecheck + lint ==="
(cd mobile && pnpm install --frozen-lockfile >/dev/null && pnpm typecheck && pnpm lint)

if [ "${1:-}" = "--expo" ] || [ "${2:-}" = "--expo" ]; then
  echo
  echo "=== expo shell: prebuild + Release simulator build (slow) ==="
  Scripts/preflight.sh >/dev/null 2>&1 || { Scripts/preflight.sh; exit 1; }
  # CocoaPods crashes on a non-UTF-8 locale.
  export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  (cd mobile && pnpm expo prebuild -p ios --clean >/dev/null)
  (cd mobile/ios && xcodebuild -workspace Beacon.xcworkspace -scheme Beacon -configuration Release \
      -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath ../../build/expo-dd build \
      | grep -E '^\*\* BUILD|[^-]error: ')
fi

if [ "${1:-}" = "--e2e" ] || [ "${2:-}" = "--e2e" ]; then
  echo
  echo "=== gate 3/3: replayed phone against the real hub in this checkout ==="
  Scripts/e2e-hub.sh
fi

echo
echo "gates green."
echo "neither of them proves the phone knows where it is — see DEVICE_CHECKLIST.md."
