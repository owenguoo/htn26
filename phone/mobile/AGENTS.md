# Expo HAS CHANGED

Read the exact versioned docs at https://docs.expo.dev/versions/v57.0.0/ before writing any code.

# This app is the mobile client

The Swift/SwiftUI client in this tree is **the** mobile client. Operators join
with Beacon; there is no browser phone page. Operator-facing features land here.

See `../CLAUDE.md` for the architecture rules that govern what may live in JS at
all: JS never touches frames, poses at rate, or the socket.
