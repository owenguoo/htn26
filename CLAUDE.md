# htn26

The Python hub (`swarm/`, `web/`, `room.json`, `pyproject.toml`) belongs to the
team. The iOS phone client lives in `phone/` — see `phone/CLAUDE.md`.

**Phone work must not modify `swarm/`, `web/`, `room.json` or `pyproject.toml`.**
The hub (`swarm/hub.py`, `swarm/protocol.py`) is the protocol source of truth;
the phone client adapts to it.
