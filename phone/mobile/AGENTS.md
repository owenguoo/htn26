# Expo HAS CHANGED

Read the exact versioned docs at https://docs.expo.dev/versions/v57.0.0/ before writing any code.

# This app is the mobile client

The Swift/SwiftUI client in this tree is **the** mobile client. The browser phone
client at `../../web/phone.js` is a prototype we read for reference and do not
extend or ship. Operator-facing features land here.

See `../CLAUDE.md` for the architecture rules that govern what may live in JS at
all: JS never touches frames, poses at rate, or the socket.
