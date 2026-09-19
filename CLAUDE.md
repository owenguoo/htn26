# htn26

The Python hub (`swarm/`, `web/`, `room.json`, `pyproject.toml`) belongs to the
team. The iOS phone client lives in `phone/` — see `phone/CLAUDE.md`.

**Phone work must not modify `swarm/`, `web/`, `room.json` or `pyproject.toml`.**
The hub (`swarm/hub.py`, `swarm/protocol.py`) is the protocol source of truth;
the phone client adapts to it.

## The mobile client is the Swift one

**`phone/` — the Swift/SwiftUI client — is the mobile client.** There is no
browser phone client anymore: `/` serves a join landing page that deep-links into
Beacon. Every operator-facing feature — UI, guidance cues, voice input, the HUD —
lands in the Swift client.

`web/console.js` is the operator console; it is still live, and its `drawHud`
remains the geometry the phone HUD mirrors.
