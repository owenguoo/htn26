# Beacon — design brief

For a designer producing one design system across the iOS app (operator phone)
and the web console. Written from the current code; every state, string, colour
and timing below exists today unless marked **NEW**.

---

## 1. What Beacon is

Beacon finds a missing person in a crowded room using the phones already in it.

- **Searchers** (3–30 people) open the Beacon iPhone app, scan a QR code, and
  hold their phone up while walking. The phone streams camera frames plus its
  position and heading to a laptop hub.
- **One operator** sits at the **web console**. They upload a reference photo of
  each missing person (up to 8). A vision model matches every frame from every
  phone against those photos.
- The console shows a **floor plan**: where each searcher is, what their camera
  covers (view cone), a **heatmap** of where the person is still likely to be,
  and sightings as they happen.
- A planner assigns each searcher a sector (`C4`) and steers them with on-phone
  cues: turn left, look up, walk 4 m. When someone is found, the nearest few
  searchers are dispatched as **responders** and guided to the spot.
- **Mission Control** is an LLM the operator can type to ("send two people to
  the back left"); in Autonomy mode it acts alone and reports what it did.

A search moves through five phases, shared by both surfaces:
**Lobby → Calibrate → Search → Found → End.**

The two users have opposite needs. The searcher is walking, arm raised, glancing
at the screen for half a second: they need **one instruction at a time, readable
at arm's length**. The operator is seated with a big screen: they need **the map,
the people, and one clear next action**.

---

## 2. Design direction

**Reference feel:** Luma's home and share sheet, Cash App's keypad, Corner's map
(screenshots supplied). What to take from them:

1. **Content is full-bleed; controls float on it.** Camera on the phone and map on
   the web run edge to edge. Controls are glass pills and circles hovering above —
   never bars that box the content in.
2. **Pills and circles only.** Floating pill tab bar, a detached round action
   button beside it (Corner's `+`), a two-icon glass capsule top-right (Luma's
   `+ 🔔`), a round glass `X` on sheets, one full-width pill CTA per screen.
3. **Real native sheets.** Grabber, detents, background scales back. No custom
   modals, no centred alert-style cards.
4. **One saturated colour can own the whole screen** (Cash App). Beacon uses this
   for exactly two moments — see §4.5.
5. **Big confident type, few words.** One bold title, one secondary line.

**What it must not be:** a stock iOS Settings-style form with a default large
title (today's join screen), or a developer dashboard of equal-weight cards
(today's console).

### Brand

- **Logo:** the existing isometric green cube on a black slab
  (`web/beacon_logo.png`) — mint top face, mid-green left face, deep-green right
  face. It is the *only* logo. It becomes the iOS app icon (cube centred on
  `#f5faf6`), the splash, the join screen hero, the web header mark, the favicon,
  and the mark on the QR join page. The current iOS icon and splash are the stock
  Expo template and must be replaced.
- **Wordmark:** "Beacon", semibold, tight tracking, set next to the cube.
- **Personality:** calm, legible, a little warm. Paper-and-green, not
  tactical-black. Light theme only on both surfaces (the app is already pinned
  light); the single exception is chrome floating over the live camera, which is
  dark glass with white ink.

---

## 3. Shared design system

One token set, two implementations (SwiftUI + CSS variables). Today there are
three disagreeing token files and five different reds; this replaces them.

### Colour

Every semantic hue has two values: **on paper** (light UI, map) and **on camera**
(over video, HUD, full-screen takeovers). Nothing else is allowed.

| Role | Meaning — identical everywhere | On paper | On camera |
|---|---|---|---|
| **Green** (brand) | you / searcher / OK / arrived / primary action | `#18834b` | `#7ae582` |
| **Amber** | possible sighting / attention / "turn" / responding | `#d97706` | `#ffb703` |
| **Red** | **a person has been found** — and nothing else at full strength | `#b72f36` | `#ff5d73` |
| **Purple** | calibration marker | `#6b4fbb` | `#6b4fbb` |
| **Blue** | heatmap only ("likely here"), max 38 % alpha | `#2563eb` | — |

Neutrals (from the console, adopt on iOS too): background `#f5faf6`, raised
`#edf6ef` / `#e2f0e6`, surface `#ffffff`, hairline `#d5e5da`, ink `#173726`,
secondary ink `#466653`, tertiary `#597562`, accent tint `#e0f5e7`, red tint
`#fcebed`. Camera chrome: ink `#ffffff` (80 % / 70 % for secondary/tertiary),
void `#000000`.

Rules: retire cyan `#4cc9f0`, `#ff3b30`, `#ff4d5e`, `#ff4d4d`, `#57d879` and
`#ffd166` — fold into the table above. System problems (Wi-Fi, tracking lost)
are shown as a red *icon* inside a neutral glass pill, never as a red surface,
so a red screen always and only means "found".

Each phone has an **identity colour + number** (`#3`) assigned by the hub. Show
it as the same chip — coloured dot, mono number, name — on the phone's own
screen, on its map dot, on its feed card and in the activity log. This chip is
the strongest thread between the two surfaces.

### Type

- **iOS:** SF Pro via Dynamic Type; SF Pro Rounded Heavy only for full-screen
  takeover text; monospaced digits for every number.
- **Web:** Geist + Geist Mono (already loaded).
- Shared scale: Display (takeovers, 40 pt), Title (bold), Headline (actions),
  Body, Caption, Readout (mono, for metres/degrees/percent).
- Numbers are raw and simple: `4.2 m`, `34°`, `41 %`, `3/4`. No invented scores.

### Shape, spacing, motion

- Radii: **pill 999** (buttons, chips, banners, tab bar), **card 14**,
  **sheet 22**, plate 8. Continuous corners on iOS. Web cards move from 10 → 14,
  buttons from 6 → pill.
- Spacing 4 / 8 / 12 / 16 / 20 / 24 (fix the 24-vs-28 disagreement at 24).
  Hit targets ≥ 44 pt on phone, ≥ 32 px on web.
- Materials: iOS Liquid Glass (`.glass` buttons, `ultraThinMaterial` chrome,
  `regularMaterial` cards). Web mimics with `backdrop-filter: blur(20px)` on
  white 72 % for anything floating over the map.
- Motion: one spring (response 0.42, damping 0.78) for things that move; 120 ms
  ease-out for takeovers in; 350 ms ease-in-out for things leaving. Web uses the
  same durations. Respect Reduce Motion: pulses become steady fills.

### Icons and words

SF Symbols on iOS, Heroicons on web, paired by shape (e.g. `qrcode.viewfinder` ↔
qr-code, `gearshape` ↔ cog-6-tooth, `scope` ↔ viewfinder-circle, `map` ↔ map).
Same fill style on both: solid for state, outline for actions.

One vocabulary, used verbatim on both surfaces and in map labels:
**Searcher · Possible sighting · Found person · Reached · Marker · Sector ·
Test person** (replaces "test candidate / test target / candidate").
Sentence case everywhere; ALL CAPS only for tiny map pills.

---

## 4. iOS app

Built with Expo Router + `@expo/ui` (real SwiftUI) for join/settings, and one
native SwiftUI view for the operator screen. Use native stack, native form
sheets with detents, glass buttons, SF Symbols — no JS-drawn imitations.

### 4.1 Structure (an appropriate amount of features)

```
Launch (cube splash) → Join → Operator ⇄ Map
                                 └─ Settings (sheet)
```

That is the whole app. No accounts, no history, no onboarding carousel.

### 4.2 Join

Today: a grouped `Form` with "Hub" and "You" sections that looks like a system
settings pane. Redesign:

- Background `#f5faf6`. Cube logo + "Beacon" top-left at Luma-header scale.
- Bold title **"Join a search"**, secondary line "Scan the code on the
  operator's screen."
- One field card: **Your name** (remembered between launches).
- Bottom-pinned full-width pill CTA, ink-black with white label:
  **Scan QR code** (`qrcode.viewfinder`) → Apple's native scanner sheet.
- Below it a quiet text button **Enter address instead** → a small native sheet
  (medium detent, grabber, round glass `X`) with the URL field and a **Join** pill.
- Joining: the CTA morphs into a spinner pill "Joining…". Errors appear as an
  inline red-icon row under the field, using the existing copy
  (`"…" is not a hub address. Scan the QR on the dashboard.`).
- Arriving by deep link (`beacon://join?hub=…`) skips straight to "Joining…".

### 4.3 Operator screen — layout

Full-bleed live camera, status bar hidden, swipe-back disabled. Floating on it,
all dark glass with white ink:

- **Top-left — identity chip:** `● #3 Dawson`, the dot in the phone's identity
  colour. Doubles as connection state (dot hollow + "Reconnecting…" when
  offline). **NEW**
- **Top-right — glass capsule with two icons** (Luma pattern):
  recalibrate (`arrow.clockwise`, rotates while active) and settings (`gearshape`).
- **Top-centre, below the safe area — the HUD stack** (§4.4).
- **Bottom — floating pill tab bar, two items: Camera · Map**, with a detached
  round glass button to its right for the **microphone** (push state: off /
  listening / sending — pulsing green ring while sending). **NEW**
  Map is the same floor plan as the console, centred on the searcher.
- **Bottom-left, above the bar — mini-map** (132 × 164, card radius 14,
  draggable, caption `41 % searched · 4 👥`). Tap = switch to the Map tab with
  the existing genie spring. Can be turned off in Settings.
- **Status pill** under the identity chip, only when something is wrong.

The searcher must never see two things saying the same thing. Priority when
several cues compete: **takeover > phase card > banner > status pill > toast**.
The turn instruction lives in the banner only; the compass chip and elevation
chevron show direction but no duplicate sentence.

### 4.4 The HUD (mirrored on the console)

Hard constraint: the operator can watch any phone's HUD live in the console, so
the HUD is drawn twice — SwiftUI Canvas on the phone, HTML canvas on the web —
from the same data, scaled by `k = width / 390`. **Design HUD elements only from
pills, rounded rects, diamonds, ticks and text** so both renderers match
exactly. Everything in §4.3, §4.5 and §4.6 is phone-only and can be fully native.

HUD elements, top to bottom:

1. **Compass tape** — 120° span, rounded-rect (radius 10k), minor ticks every 5°,
   majors every 15°, centre caret. Coloured **marker chips** ride on it
   (pill, 15k tall) for stage, target, ping, sound; `◀ ▶` when off-tape.
   Pick one tape style for both renderers (today the phone's is white, the
   console's is dark navy): use **dark glass `rgba(12,17,32,0.82)` with white
   ticks**.
2. **Instruction banner** — the single most important element. A pill, 15k bold,
   toned green/amber/red: `← Turn left 40°` · `Turn right 40° →` ·
   `↑ Walk to Sam · 6 m` · `Facing Sam ✓ hold it` · `Scanning C4…` ·
   `Hold your phone up` · `Candidate found · 4 m` · `Sound heard · left`.
3. **"Looking for" pill** — small, dark, names the people being searched for.
4. **Toast** — white pill, operator messages ("📣 …", rendered with
   `megaphone.fill`).
5. **Detection box** — 2 pt red rounded box on a matched person with a filled
   label tag. (Delete the second, divergent box renderer.)
6. **AR diamond** — filled diamond in the cue colour pinned in space, with a dark
   pill label `SAM · 4.2 m`.
7. **Elevation cue** — `arrow.up.circle.fill` + `Look up 34°`, amber, offset
   above/below centre.

### 4.5 Takeovers — when the whole screen changes colour

The Cash App moment. A hub `flash` command fills the screen edge to edge with a
solid colour, fades in over **120 ms ease-out**, holds, then **NEW:** instead of
just fading, it contracts into the banner pill so the message persists.
Text: SF Rounded Heavy 40 pt, centred, ink auto-chosen by luminance, with one
large symbol above it. Pair with a haptic (success / heavy).

| Moment | Colour | Text | Hold |
|---|---|---|---|
| Reached your sector / reached the person | green `#7ae582`, dark ink | **You're there ✓** | 1.5 s |
| This phone's camera found the person | red `#ff5d73`, white ink | **You found them! / Stay on them** | 2.5 s |
| Someone else found them; you're a responder | red `#ff5d73`, white ink | **Person found! / Follow the arrow** | 1.8 s |

Nothing else may ever fill the screen with colour.

### 4.6 The pulsing edge

When a sound is heard or a find is off-screen, the bezel edge **on that side**
(left / right / top) glows red: a gradient band ~52 pt wide (14 % of width),
alpha 0.9 → 0.28 → 0 inward, hugging the display's rounded corners. Fades in
0.5 s, then breathes **opacity 0.95 ↔ 0.48, 0.9 s ease-in-out, forever**, fades
out in 0.35 s. One red for both causes; the banner says which
(`waveform` "Sound heard · left" vs `person.fill` "Person found · right").
Think Siri's edge glow, single-sided and directional.

On the map, the same rhythm: found person = red ring expanding over 1.1 s;
ping = amber ring 6 → 24 pt each second.

### 4.7 Phase screens

Today these are centred material cards. Redesign as **bottom sheets pinned over
the live camera** (non-dismissable, medium height, radius 22, regular material,
light), so the camera stays visible and it feels like the Luma share sheet:

- **Lobby** — identity chip large (`#3`, colour), title **You're in**, line
  "The operator starts the search." A quiet live count: "4 searchers joined".
- **Calibrate** — the most important screen to get right. Camera full-bleed
  with a soft dark scrim and a **rounded-square viewfinder cut-out with four
  corner brackets**. Sheet: title **Calibrate**, line "Point at a printed marker
  until it locks.", and a small thumbnail of what a marker looks like.
  When a marker enters view the brackets **snap to the marker's outline**
  (purple → green), a ring fills for ~1 s, success haptic, then the sheet
  morphs to **✓ Calibrated — "You're located. The operator starts the search."**
  for 2.2 s and drops to Lobby. Marker too far/oblique (> 4.5 m or > 60°):
  brackets amber, line "Move closer, face it straight on."
- **Recalibrate** (top-right button, or automatic) — same viewfinder, as a
  dismissable sheet with the round glass `X`.
- **End** — `flag.checkered`, **Search complete**, "You can lower your phone.",
  pill button **Leave**.

### 4.8 Status pill

Dark glass pill with a coloured icon; expands to a two-line card when there's a
hint. Exact sentences (keep): `Connecting…` / `Reconnecting…` (+ "Check the
venue Wi-Fi" after 15 s) · `Starting the camera…` · `Not located yet` ·
`Needs recalibrating` — "Point the camera at a printed marker" · `Tracking lost`
— "Move slowly, find a marker" · `Tracking is shaky` — "Slow down, camera up" ·
`Camera stopped` — "Reopen the app if it stays" · `Phone is hot` — "Sending
fewer frames" · `Position may be drifting` — "Glance at a marker".
Healthy = no pill at all.

### 4.9 Map tab and Settings sheet

- **Map:** full-bleed floor plan in the paper palette, identical drawing to the
  console (stage block, heat, cones, numbered identity dots, amber possible
  sightings, red found people with responder lines, purple marker). Title
  **Search map**, readout `12 × 20 m · 41 % searched · 4 searching`, collapsible
  legend chip bottom-left. "You" is always centred and ringed.
- **Settings:** native form sheet, detents 60 % / 100 %, grabber, round glass
  `X`. Sections: **Over the camera** (Marker outlines, Mini-map) · **Voice**
  (Microphone toggle, status, the existing privacy footers) · **Diagnostics**
  (hub, tracking, located by, room position, frames, latency, thermal, last
  error — mono readouts) · **Leave the search** (destructive).

---

## 5. Web console

Same paper-and-green system, Geist, Heroicons, pills, 14 px cards, glass
floating controls. The redesign is mostly **regrouping**; almost every feature
already exists.

### 5.1 Problems today

- The primary action (Start search) sits in an unbordered strip under an empty
  `<h1>`; destructive **Reset** sits beside it with no confirmation.
- Phone counts are stated five ways; "area searched" three ways.
- Three separate activity feeds (autonomy cards, Mission Control drawer,
  Activity card), each truncated differently.
- Four overlay idioms (dialog, custom modal, popover, drawer that reflows the
  page). The map is a fixed 480 px.
- Rehearsal controls are buried in Settings while their effects are on the map.
- "People to find" and "Search status" are two cards about the same people;
  **Confirm sighting** is inside the phone viewer, its result behind it.
- Inference offline and "not authenticated" have no UI at all.
- `join.html` is a dark navy/cyan page with no logo — a different product.

### 5.2 New layout

```
┌ Top bar ───────────────────────────────────────────────────────────────┐
│ ◼ Beacon   Lobby ─ Calibrate ─ ●Search ─ Found ─ End   03:41  [End search] │
│            3/4 calibrated · 4 searching      ● Model online   QR   ⚙     │
├──────────┬───────────────────────────────────────────────┬─────────────┤
│ PEOPLE   │                                               │ ACTIVITY    │
│ person   │            MAP (hero, fills height)           │ one timeline│
│ cards    │   floating glass toolbars inside the canvas   │             │
│          │                                               │ [Ask Mission│
│ + Add    │                                               │  Control… ] │
├──────────┴───────────────────────────────────────────────┴─────────────┤
│ CAMERAS  filmstrip of feed cards, identity chips, badges               │
└────────────────────────────────────────────────────────────────────────┘
```

- **Top bar:** logo + wordmark; a **phase stepper** showing all five phases with
  the current one filled green; the elapsed timer (Geist Mono); **one** primary
  pill button whose label is the next step (`Start search` / `End search`), with
  the readiness sentence beside it ("2 of 4 phones have scanned the marker").
  Right: model status chip (`Model online` / `Model offline` in amber), **Join QR**
  popover, Settings. **Reset** moves into a `⋯` menu with a confirm dialog.
- **People rail (left, 300 px):** merges "People to find" + "Search status". One
  card per person: reference photo, name, a status chip —
  `Searching` (green) → `Possible · 3 phones` (amber) → `Found · #3` (red) →
  `Reached 3/3` (green check) — and, when a match is pending, an inline
  **Confirm sighting** pill with the matched frame thumbnail, similarity and
  confidence as raw numbers. `+ Add person` is the dropzone.
- **Map (hero):** fills the available height. Controls float inside it as glass
  pills, Corner-style: top-left segmented **2D · 3D**; top-right **Layers**
  (Heat, Sectors, Cones, Legend); bottom-left collapsible legend; bottom-right
  scale bar; a **Marker** pill and a **Scan** menu (Start/Stop, Rebuild, Reset).
  Readout chip: `12 × 20 m · Most likely C4 · 41 %`. Same drawing language and
  pulse timings as the phone map.
- **Activity rail (right, 340 px):** one timeline merging planner log, autonomy
  actions and Mission Control replies, filterable by chips (All · Finds ·
  Autonomy · Planner), each row tagged with the identity chip. Evidence expands
  inline and highlights the map. The Mission Control composer is docked at the
  bottom with the **Autonomy** switch in the rail header. It overlays; it never
  reflows the map.
- **Cameras (bottom filmstrip):** 16:10 feed cards with identity chip and one
  state badge (`Live`, `No signal`, `Offline`, `Responding`, `Arrived`,
  `Found it`, `Speaking`). Offline cards at 65 % opacity.
- **Phone inspector:** clicking a feed or a map dot opens a **right-side sheet**
  over the Activity rail (not a full-screen modal), so the map stays visible:
  live frame with the mirrored HUD, badges, raw readouts (sector, position,
  facing, tilt, fps, latency), and **direct action pills — Ping here · Message ·
  Look at… · Remove**. (Today these commands are only reachable by typing to
  Mission Control; the buttons need small hub support from the team.)
- **Rehearsal mode:** a switch in Settings that, when on, shows a persistent
  amber `Rehearsal` chip in the top bar and adds **Place test person** to the map
  toolbar. Surface the ten authored drill scenarios (currently orphaned) as a
  menu there.
- **Settings dialog:** only true settings — match sensitivity, planner on/off,
  responders per find, rehearsal mode.
- **One overlay system:** popover (small), side sheet (inspector), dialog
  (confirmations, settings). `Esc` closes the top one. Show shortcuts as `<kbd>`
  hints in tooltips (`/`, `M`, `P`, `H`, `←/→`).

### 5.3 Console states

- **No phones:** the map area shows the Join QR large, centred, with "Scan to
  join with the Beacon app". Start disabled: "Waiting for phones to join".
- **Calibrating:** stepper on Calibrate; uncalibrated phones' dots are hollow.
- **Found:** the person card turns red-tinted, the map ring pulses, the
  top bar flashes the same red for 1.8 s — the console's echo of the phone
  takeover — and the timeline pins the find.
- **Model offline / not authenticated:** amber chip in the top bar + an inline
  explanation in the People rail; a proper sign-in card instead of nothing.

### 5.4 Join landing page (`/`)

Re-skin to the shared system: `#f5faf6` background, cube logo, "Beacon",
"Join this search from the Beacon app", one ink-black pill **Open in Beacon**,
hub address in Geist Mono underneath, quiet link to the console. It should look
like the app's own Join screen rendered in a browser.

---

## 6. What "seamless" means — acceptance checklist

1. Same cube logo on app icon, splash, join screen, web header, favicon, join page.
2. A screenshot of the phone Map tab and the console map are indistinguishable
   in colour, glyphs, labels and pulse timing.
3. The HUD in the console's phone inspector is pixel-equivalent to the phone's.
4. Every phone is `● #n Name` in its identity colour everywhere it appears.
5. Green / amber / red / purple / blue mean the same thing on both surfaces;
   a full red surface only ever means "person found".
6. Same nouns, same sentences, sentence case.
7. Buttons are pills, cards are 14, sheets are 22, floating controls are glass —
   on both.
