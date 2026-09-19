# Team setup — getting SwarmSight onto your phone

One person runs the hub on their laptop. Everyone else builds the iOS app on
their own Mac, installs it on their own iPhone, and joins over Wi-Fi.

There are two roles. **Part 1 is the host only.** **Parts 2 and 3 are everyone,
including the host.**

Budget 30–45 minutes for your first build. It is almost all downloads.

## What you need

Per person:

- A **Mac** with Xcode 16 or newer (we build with 27) — the app has Swift/ARKit
  native code, so there is no way around a Mac.
- A **real iPhone** with ARKit and iOS 17+. The Simulator cannot run this; ARKit
  does not exist there.
- A free **Apple ID**. No paid developer account needed.
- **Node 22** (the app pins `>=22 <23`) and **pnpm 11**.
- A USB cable for the first install.

Host only, on top of that: **uv** (`brew install uv`) to run the Python hub.

Everyone must be on the **same Wi-Fi network**, and that network must allow
devices to talk to each other. See the troubleshooting section — this is the
single most common failure.

## Part 0 — repo access

Ask the repo owner to add you as a collaborator on `owenguoo/htn26`, then:

```bash
git clone https://github.com/owenguoo/htn26.git
cd htn26
```

The phone app lives in `phone/mobile`. Check with the team which branch to
build — the phone client's work is not always merged to `main` yet.

## Part 1 — host: run the hub

Only one person does this. Whoever does it is the machine everybody's phone
talks to, so pick someone whose laptop will stay open and on the network.

**1. Start the hub.**

```bash
uv run python -m swarm.hub
```

It prints three things worth keeping:

```
Operator code: <code>

  Swarm Sight hub
  Console:     http://localhost:8000/console
  Phones join: http://192.168.x.x:8000/
```

The operator code is for logging into the console in the browser. Phones do not
need it — the phone socket takes no authentication.

**2. Allow the firewall prompt.** macOS asks whether Python may accept incoming
connections. Say yes. If you miss it, nothing can reach you.

**3. Ignore the HTTPS warning.** The hub may print a note that iPhone cameras
need HTTPS. That applies to the *browser* phone client, which needs a secure
context for `getUserMedia`. The native app uses ARKit and talks plain
`ws://<lan-ip>:8000/ws/phone`, so you do not need to run `scripts/make-cert.sh`
unless someone is joining from Safari.

**4. Prove you are reachable before anyone builds anything.** On a phone, open
Safari and go to `http://<the-lan-ip-it-printed>:8000/console`. If that page
loads, the network is fine. If it does not, fix that now — see troubleshooting.

**5. Keep the laptop awake.**

```bash
caffeinate -di
```

Optional: copy `.env.example` to `.env` if you want the full inference stack.
Without it the hub runs with mock rehearsal enabled, which is fine for testing
that phones connect.

## Part 2 — everyone: build the app on your iPhone

**1. Xcode, once.**

```bash
sudo xcodebuild -license accept
```

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**2. Node 22 and pnpm.** If you use nvm:

```bash
nvm install 22 && nvm use 22
```

```bash
corepack enable
```

`corepack` picks up the exact pnpm version pinned in `package.json`, so you do
not need to install pnpm yourself.

**3. Developer Mode on the iPhone.** Settings → Privacy & Security → Developer
Mode → on. **This requires a restart**, so do it now rather than while everyone
waits for you.

**4. Give yourself a unique bundle identifier.** With free Apple ID signing, an
app identifier can only be registered by one person's team — if two of us build
`com.swarmsight.SwarmSight`, the second gets a signing error. In
`phone/mobile/app.json`, change:

```json
"bundleIdentifier": "com.swarmsight.SwarmSight"
```

to something like `"com.swarmsight.SwarmSight.yourname"`.

**Do not commit this change.** It is yours alone.

**5. Install dependencies and generate the native project.**

```bash
cd phone/mobile && pnpm install
```

```bash
pnpm prebuild
```

`prebuild` regenerates `ios/` from `app.json` and the `withSwarmSight` config
plugin. That folder is gitignored and disposable — rerun this any time the
native config changes, or when something looks corrupted.

**6. Set your signing team.** Open the workspace:

```bash
open ios/SwarmSight.xcworkspace
```

Select the **SwarmSight** target → **Signing & Capabilities** → check
*Automatically manage signing* → set **Team** to your personal team. If your
Apple ID is not listed, add it under Xcode → Settings → Accounts.

**7. Build and install it.** Plug the phone in, unlock it, and:

```bash
npx expo run:ios --configuration Release --device
```

Pick your phone when prompted.

**Build Release, not the default.** The default `pnpm ios` builds a *development
client*, which loads its JavaScript from a Metro server on the Mac that built
it. That app will not start on its own — if that Mac sleeps, walks away, or
leaves the network, the app is dead. `--configuration Release` embeds the
JavaScript bundle, so the phone only needs the hub. Use it for anything you plan
to demo.

**8. Trust yourself on the phone.** First launch will refuse: Settings → General
→ VPN & Device Management → your Apple ID → Trust.

**A free-signed app stops launching after 7 days.** Rebuild with step 7 when it
does. Nothing is lost; it takes a couple of minutes once the toolchain is warm.

## Part 3 — join the hub

**1.** The host opens `http://localhost:8000/console` and clicks **Join QR** — it shows a QR code and
the join URL.

**2.** Open SwarmSight on your phone. It starts on the join screen. Scan the QR.

**3.** Or type the address by hand if the QR is awkward. The app accepts a bare
`192.168.x.x:8000` and works out the socket itself.

**4.** Accept the local-network permission prompt on first launch. Declining it
blocks the connection silently, and the only way back is Settings → SwarmSight →
Local Network.

**5.** You should appear on the host's console within a second or two. If the
console still says "Waiting for phones", go to troubleshooting.

You never type the hub address into a file — the QR carries it. The hub's own
LAN IP changes with the network, so rescan after switching Wi-Fi.

## When it doesn't work

**Phone can't reach the hub, but both are on the same Wi-Fi.** Almost always
client isolation: conference, campus and guest networks routinely block
device-to-device traffic while giving everyone internet. Confirm by opening
`http://<lan-ip>:8000/console` in the phone's Safari. Two ways out:

- The host turns on a personal hotspot and everyone joins that. Fastest fix, and
  it keeps latency low because traffic stays local.
- The host runs a tunnel and passes the public URL to the hub:

```bash
uv run python -m swarm.hub --public-url https://<name>.trycloudflare.com
```

  Then the QR carries the tunnel URL, the app connects over `wss://` with a real
  certificate, and it works from any network. Costs you latency on the JPEG
  stream, so prefer the hotspot when you are in one room.

**"Failed to register bundle identifier."** Someone else already claimed that
identifier. Redo Part 2 step 4 with a more unique suffix, then `pnpm prebuild`
again.

**App installs, opens, then dies — or says it cannot connect to a development
server.** You built the default Debug configuration. Rebuild with
`--configuration Release`.

**"Untrusted Developer" on launch.** Part 2 step 8.

**App stopped opening after about a week.** The free signing certificate
expired. Rebuild.

**Hub prints a LAN IP starting with 169.254.** No real network. Reconnect Wi-Fi.

**Phone connects, but position is wrong or drifts.** That is positioning, not
networking — printed markers and a measured `venue.json`. See
`DEVICE_CHECKLIST.md`, which covers the physical setup the test suite cannot
prove.

## The short version, once you've done it once

Host:

```bash
uv run python -m swarm.hub
```

Everyone:

```bash
cd phone/mobile && pnpm install && pnpm prebuild && npx expo run:ios --configuration Release --device
```

Then scan the QR from the host's console (**Join QR**).
