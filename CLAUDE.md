# htn26

The Python hub (`swarm/`, `web/`, `room.json`, `pyproject.toml`) belongs to the
team. The iOS phone client lives in `phone/` — see `phone/CLAUDE.md`.

**Phone work must not modify `swarm/`, `web/`, `room.json` or `pyproject.toml`.**
The hub (`swarm/hub.py`, `swarm/protocol.py`) is the protocol source of truth;
the phone client adapts to it.

## The mobile client is the Swift one

**`phone/` — the Swift/SwiftUI client — is the mobile client. `web/phone.js` is
not.** The browser client was the prototype that proved the idea; it is no longer
a thing we build on or ship to operators. Every operator-facing feature — UI,
guidance cues, voice input, the HUD — lands in the Swift client.

`web/phone.js` stays useful as a **behavioural reference**: read it to learn what
the hub sends and expects, and to match wording, thresholds and timings. Do not
extend it, and do not treat a gap in the Swift client as covered because the web
client has it.

`web/console.js` and `web/dashboard.js` are a different matter — those are the
operator console and dashboard, they are still live, and `console.js`'s `drawHud`
remains the geometry the phone HUD mirrors.
