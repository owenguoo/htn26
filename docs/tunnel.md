# Public URL for the hub (Cloudflare tunnel)

Phones need HTTPS for the camera, and venue Wi-Fi often blocks phone → laptop traffic. A Cloudflare
tunnel gives the hub a real HTTPS address with no certificate warnings, reachable from anywhere.

## One-time setup (needs a domain on your Cloudflare account)

```sh
cloudflared tunnel login                        # browser sign-in; pick your domain
scripts/tunnel.sh setup swarm.yourdomain.com    # tunnel + DNS record + ~/.cloudflared/config.yml
```

The hostname is saved in `.env` as `SWARM_TUNNEL_HOSTNAME`.

## Every run

```sh
scripts/tunnel.sh run
```

Starts the tunnel and the hub together, with the join QR pointing at the public URL. Phones open
`https://swarm.yourdomain.com/`, the console is at `/console`.

No domain yet? `scripts/tunnel.sh quick` uses a throwaway `trycloudflare.com` URL that changes on
every run (fine for testing, not for a demo: the QR changes with it).

## Protect the console

A public URL means anyone with the link can drive the search. In the Cloudflare dashboard, under
Zero Trust → Access → Applications, add a self-hosted application:

- **Operator**: `swarm.yourdomain.com/console` and a second application for `swarm.yourdomain.com/api`,
  policy Allow → Emails → your address (one-time PIN is enough).
- Leave the rest of the site public so audience phones can join without signing in: `/`, `/web/*`,
  `/ws/phone`, `/api/qr.svg`.

Access sets a cookie, so the console's WebSocket (`/ws/console`) keeps working once you're signed in.

## Notes

- **Bandwidth:** with the tunnel, every phone's video leaves your laptop and comes back. Ten phones
  at 10 fps is roughly 2.5 Mbps up. If the venue lets phones reach your laptop directly, keep phones
  on the LAN (`https://<laptop-ip>:8443/`) and use the tunnel for the console and remote viewers.
- **Same-origin checks** keep working through the tunnel: cloudflared runs on this machine, so
  uvicorn trusts its forwarded headers. Running cloudflared elsewhere needs `FORWARDED_ALLOW_IPS`.
- **The inference bridge** can post to `https://swarm.yourdomain.com/api/detections` with
  `SWARM_BRIDGE_KEY`; give that path its own Access bypass policy for service tokens, or leave it
  off Access and rely on the bridge key.
- Keep the laptop awake and plugged in: the tunnel dies with the machine.
