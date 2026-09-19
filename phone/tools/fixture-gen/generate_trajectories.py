#!/usr/bin/env python3
"""Generate SYNTHETIC stand-in trajectory fixtures.

These are NOT recorded ARKit output. PLAN.md's human task list says to record a
real two-minute walk on a device and dump frame.camera.transform,
frame.timestamp and frame.camera.trackingState to JSON; that has not happened
yet, and tests need something to run against in the meantime.

Every file this writes sets "synthetic": true and says so in "note". Replace
them with a real recording as soon as one exists: real ARKit motion has drift,
dropout and jitter characteristics this script approximates but does not
reproduce. Anything asserting on the *character* of the motion (drift rate,
re-lock time) is only meaningful against a device recording.

The construction that makes the fixtures useful for Gate 3 is that ground truth
is known by design:

    reported_arkit_pose(t) = Drift(t) . S . true_venue_pose(t)

where S is the arbitrary rigid transform between the venue frame and wherever
the ARSession happened to start (gravity-aligned, so yaw and position only), and
Drift(t) is a slow random walk in x, z and yaw. A marker that is static in the
venue is reported by ARKit at Drift(t) . S . marker_venue_pose, so

    worldOriginTransform(observed, marker_venue) == Drift(t) . S

which is exactly the transform that removes the drift. Both the drifted samples
and the true venue poses are written out, so a test can measure whether a
correction actually reduced error rather than just moved things around.
"""

import json
import math
import os
import random

FPS = 60.0
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(REPO, "Fixtures")

# ---------------------------------------------------------------- linear algebra


def mat_identity():
    return [[1.0 if i == j else 0.0 for j in range(4)] for i in range(4)]


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def rot_y(theta):
    c, s = math.cos(theta), math.sin(theta)
    return [[c, 0.0, s, 0.0], [0.0, 1.0, 0.0, 0.0], [-s, 0.0, c, 0.0], [0.0, 0.0, 0.0, 1.0]]


def rot_x(theta):
    c, s = math.cos(theta), math.sin(theta)
    return [[1.0, 0.0, 0.0, 0.0], [0.0, c, -s, 0.0], [0.0, s, c, 0.0], [0.0, 0.0, 0.0, 1.0]]


def rot_z(theta):
    c, s = math.cos(theta), math.sin(theta)
    return [[c, -s, 0.0, 0.0], [s, c, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]]


def translation(x, y, z):
    m = mat_identity()
    m[0][3], m[1][3], m[2][3] = x, y, z
    return m


def from_basis(x_axis, y_axis, z_axis, origin):
    """Column-major basis into a row-indexed 4x4."""
    return [
        [x_axis[0], y_axis[0], z_axis[0], origin[0]],
        [x_axis[1], y_axis[1], z_axis[1], origin[1]],
        [x_axis[2], y_axis[2], z_axis[2], origin[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def normalize(v):
    n = math.sqrt(sum(c * c for c in v))
    return tuple(c / n for c in v) if n > 1e-9 else (0.0, 0.0, 0.0)


def column_major(m):
    """simd_float4x4 stores columns; Trajectory.matrix(from:) reads them in order."""
    return [round(m[row][col], 6) for col in range(4) for row in range(4)]


def quat_from_matrix(m):
    """Shepperd's method. Returns x, y, z, w."""
    t = m[0][0] + m[1][1] + m[2][2]
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        w, x = 0.25 * s, (m[2][1] - m[1][2]) / s
        y, z = (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s
    elif m[0][0] > m[1][1] and m[0][0] > m[2][2]:
        s = math.sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2
        w, x = (m[2][1] - m[1][2]) / s, 0.25 * s
        y, z = (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s
    elif m[1][1] > m[2][2]:
        s = math.sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2
        w, x = (m[0][2] - m[2][0]) / s, (m[0][1] + m[1][0]) / s
        y, z = 0.25 * s, (m[1][2] + m[2][1]) / s
    else:
        s = math.sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2
        w, x = (m[1][0] - m[0][1]) / s, (m[0][2] + m[2][0]) / s
        y, z = (m[1][2] + m[2][1]) / s, 0.25 * s
    n = math.sqrt(x * x + y * y + z * z + w * w)
    return [round(x / n, 6), round(y / n, 6), round(z / n, 6), round(w / n, 6)]


# ------------------------------------------------------------------------- venue
#
# Venue frame: +X east along the stage, +Y up, +Z out from the stage, origin on
# the floor below the centre of the primary marker. Room is 10 m wide and 8 m
# deep, stage wall at z = 0.
#
# Marker poses use the ARImageAnchor convention: image in the anchor's local x-z
# plane, +Y the normal out of the print, local -Z the image's up direction.

# Widths are placeholders that PRINT ON A4 PORTRAIT AT TRUE SIZE, which is the
# only reason they are these numbers: a 296.5 mm marker is wider than A4 and
# cannot be printed full size without A3, and a marker printed "to fit" is a
# marker whose declared width is a lie. Measure with a tape after printing and
# put the real number in venue.json regardless.
MARKERS = [
    # id, centre, outward normal, measured width, primary
    ("marker-primary", (0.000, 1.600, 0.000), (0, 0, 1), 0.1800, True),
    # A second marker on the *same* wall, close enough to the primary to be in
    # frame at the same time. Co-visible markers are what make averaging worth
    # anything: two independent detection errors partly cancel, and a
    # misdetection is visible as disagreement rather than being applied.
    # Markers on separate walls can never do this.
    ("marker-stage-left", (-1.420, 1.585, 0.010), (0, 0, 1), 0.1500, False),
    ("marker-east", (4.980, 1.550, 3.020), (-1, 0, 0), 0.1500, False),
    ("marker-west", (-5.010, 1.520, 3.050), (1, 0, 0), 0.1500, False),
    ("marker-rear", (0.020, 1.580, 7.950), (0, 0, -1), 0.1800, False),
]


def marker_matrix(centre, normal):
    y_axis = normalize(normal)
    z_axis = (0.0, -1.0, 0.0)  # image "up" is local -Z, so local +Z points down
    x_axis = normalize(cross(y_axis, z_axis))
    z_axis = cross(x_axis, y_axis)
    return from_basis(x_axis, y_axis, z_axis, centre)


def write_venue():
    markers = []
    for marker_id, centre, normal, width, primary in MARKERS:
        m = marker_matrix(centre, normal)
        markers.append({
            "id": marker_id,
            "physicalWidth": width,
            "physicalHeight": round(width * 1.4142, 4),
            "position": [round(c, 4) for c in centre],
            "quaternion": quat_from_matrix(m),
            "isPrimary": primary,
            "note": "SYNTHETIC placeholder. Measure the printed marker with a tape and "
                    "re-measure its position relative to the primary marker on the day.",
        })
    venue = {
        "id": "hth-main-hall",
        "name": "Hack the North — main hall (placeholder)",
        "note": "Loaded at runtime, never compiled in. Replace every number here with "
                "tape-measured values on the day; changing venue must need no rebuild.",
        "orchestratorURL": "ws://CHANGE-ME:8765/device",
        "markers": markers,
        "thresholds": {
            "rejectPositionMeters": 1.5,
            "rejectRotationDegrees": 25.0,
            "maxStepMeters": 0.25,
            "maxStepDegrees": 5.0,
        },
    }
    path = os.path.join(FIXTURES, "venue.json")
    with open(path, "w") as handle:
        json.dump(venue, handle, indent=2)
        handle.write("\n")
    return path


# -------------------------------------------------------------------- trajectory


def camera_pose(position, yaw, pitch, roll):
    """Camera looks down -Z with +Y up. Yaw is about venue +Y, measured from -Z."""
    m = mat_mul(rot_y(yaw), mat_mul(rot_x(pitch), rot_z(roll)))
    m[0][3], m[1][3], m[2][3] = position
    return m


def walk_path(t, loop_seconds, half_width, near, far):
    """Perimeter of a rectangle, walked at constant speed."""
    perimeter = 2 * (2 * half_width) + 2 * (far - near)
    distance = (t / loop_seconds) * perimeter % perimeter
    w, d = 2 * half_width, far - near
    if distance < w:
        return (-half_width + distance, near)
    distance -= w
    if distance < d:
        return (half_width, near + distance)
    distance -= d
    if distance < w:
        return (half_width - distance, far)
    distance -= w
    return (-half_width, far - distance)


def build(name, seconds, seed, *, sweep_amplitude, loop_seconds, stationary,
          degraded_windows, dropout_windows, interruption, note):
    rng = random.Random(seed)
    count = int(seconds * FPS)
    # A plausible uptime: the phone has been awake for a few hours.
    t0 = round(rng.uniform(8_000, 40_000), 4)

    # Where the ARSession happened to start, relative to the venue. Gravity
    # alignment means this is yaw and position only — never pitch or roll.
    session_yaw = rng.uniform(-math.pi, math.pi)
    session_offset = (rng.uniform(-3, 3), 0.0, rng.uniform(-3, 3))
    S = mat_mul(translation(*session_offset), rot_y(session_yaw))

    drift_x = drift_z = drift_yaw = 0.0
    samples, truth, marker_events = [], [], []
    # ARKit delivers every anchor it updated in a single didUpdate callback, so
    # the throttle is per callback, not per marker. Rate-limiting each marker
    # independently would drift them out of phase and they would never appear in
    # the same batch — which is exactly the case multi-marker averaging exists
    # for.
    last_batch = None
    seen_markers = set()

    for i in range(count):
        t = i / FPS

        if stationary:
            # A phone held roughly still and swept: a couple of centimetres of
            # hand drift and nothing else. Near-zero baseline, which is what
            # Gate 5 must refuse to guess a scale from.
            x, z = 0.02 * math.sin(t * 0.4), 3.0 + 0.018 * math.sin(t * 0.31)
        else:
            x, z = walk_path(t, loop_seconds, 3.6, 1.4, 6.4)
            x += 0.06 * math.sin(t * 2.1)  # lateral sway of a walking gait

        # Held at chest height with a gait bob at about 2 Hz.
        if stationary:
            # Standing still: no gait, just breathing and a tiring arm.
            y = 1.48 + 0.004 * math.sin(t * 2 * math.pi * 0.28)
        else:
            y = 1.48 + 0.022 * math.sin(t * 2 * math.pi * 1.9) + 0.006 * math.sin(t * 5.3)

        # Operators sweep: they are not seated and not pointing one way.
        yaw = sweep_amplitude * math.sin(t * 2 * math.pi / 7.3) + 0.4 * math.sin(t * 0.77)
        pitch = 0.05 * math.sin(t * 2 * math.pi * 1.9 + 0.8) - 0.04
        roll = 0.03 * math.sin(t * 2 * math.pi * 0.95)

        # Hand tremor and sensor noise, in millimetres and tenths of a degree.
        jitter = (rng.gauss(0, 0.0012), rng.gauss(0, 0.0010), rng.gauss(0, 0.0012))
        angular_jitter = (rng.gauss(0, 0.0009), rng.gauss(0, 0.0011), rng.gauss(0, 0.0008))

        true_pose = camera_pose((x, y, z), yaw, pitch, roll)
        truth.append((round(t0 + t, 5), true_pose))

        state = "normal"
        for start, end, reason in degraded_windows:
            if start <= t < end:
                state = "limited." + reason
        if interruption and interruption[0] <= t < interruption[1]:
            state = "notAvailable"

        # ARKit drift: a slow random walk in x, z and yaw. Gravity alignment
        # pins pitch and roll, and height barely moves, so y drift stays small.
        # Drift accelerates while tracking is degraded, which is the whole
        # reason re-sighting a marker matters.
        scale = 6.0 if state != "normal" else 1.0
        drift_x += rng.gauss(0, 0.00035) * scale
        drift_z += rng.gauss(0, 0.00035) * scale
        drift_yaw += rng.gauss(0, 0.00012) * scale
        drift = mat_mul(translation(drift_x, 0.0, drift_z), rot_y(drift_yaw))

        reported = mat_mul(drift, mat_mul(S, true_pose))
        reported[0][3] += jitter[0]
        reported[1][3] += jitter[1]
        reported[2][3] += jitter[2]
        reported = mat_mul(
            reported,
            mat_mul(rot_x(angular_jitter[0]), mat_mul(rot_y(angular_jitter[1]), rot_z(angular_jitter[2]))),
        )

        skip = any(start <= t < end for start, end in dropout_windows)
        if not skip:
            samples.append({
                "t": round(t0 + t, 5),
                "transform": column_major(reported),
                "trackingState": state,
            })

        # Marker sightings: near enough, inside the lens, and not edge-on.
        if state == "notAvailable":
            continue
        if last_batch is not None and t - last_batch < 0.25:
            continue
        forward = (-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch))
        batch_emitted = False
        for marker_id, centre, normal, width, _ in MARKERS:
            to_marker = (centre[0] - x, centre[1] - y, centre[2] - z)
            distance = math.sqrt(sum(c * c for c in to_marker))
            if distance > 4.5 or distance < 0.4:
                continue
            direction = normalize(to_marker)
            if sum(a * b for a, b in zip(direction, forward)) < math.cos(math.radians(28)):
                continue  # outside the usable part of the lens
            if sum(-a * b for a, b in zip(direction, normalize(normal))) < math.cos(math.radians(55)):
                continue  # too oblique to detect reliably
            # Detection noise grows with distance and obliquity.
            noise = 0.004 + 0.006 * (distance / 4.5)
            observed = mat_mul(drift, mat_mul(S, marker_matrix(centre, normal)))
            observed[0][3] += rng.gauss(0, noise)
            observed[1][3] += rng.gauss(0, noise)
            observed[2][3] += rng.gauss(0, noise)
            observed = mat_mul(observed, rot_y(rng.gauss(0, 0.004)))
            marker_events.append({
                "t": round(t0 + t, 5),
                "markerID": marker_id,
                "transform": column_major(observed),
                "isUpdate": marker_id in seen_markers,
                "estimatedPhysicalWidth": round(width * rng.uniform(0.97, 1.03), 5),
            })
            seen_markers.add(marker_id)
            batch_emitted = True
        if batch_emitted:
            last_batch = t

    interruptions = []
    if interruption:
        interruptions.append({
            "startT": round(t0 + interruption[0], 5),
            "endT": round(t0 + interruption[1], 5),
        })

    return {
        "name": name,
        "recordedAt": "2026-09-19T05:00:00Z",
        "device": "synthetic (no device recording exists yet)",
        "worldAlignment": "gravity",
        "synthetic": True,
        "note": note,
        "intrinsics": {
            "fx": 1449.5, "fy": 1449.5, "cx": 959.5, "cy": 719.5,
            "imageWidth": 1920, "imageHeight": 1440,
        },
        "samples": samples,
        "markerEvents": marker_events,
        "interruptions": interruptions,
        "groundTruth": [
            {"t": t, "transform": column_major(pose), "trackingState": "normal"}
            for t, pose in truth
        ],
    }


SHARED_NOTE = (
    "SYNTHETIC — generated by tools/fixture-gen/generate_trajectories.py, not recorded "
    "on a device. Replace with a real ARKit recording (PLAN.md, human task 2). "
    "groundTruth holds the true venue-frame pose for every sample; samples hold the "
    "same motion seen through an arbitrary session origin plus accumulated drift."
)


def main():
    os.makedirs(FIXTURES, exist_ok=True)
    written = [write_venue()]

    specs = [
        ("trajectory-walk-2min.json", build(
            "walk-2min", 120, 20260919,
            sweep_amplitude=1.05, loop_seconds=38.0, stationary=False,
            degraded_windows=[], dropout_windows=[], interruption=None,
            note=SHARED_NOTE + " A clean two-minute perimeter walk with camera sweep.")),
        ("trajectory-degraded-90s.json", build(
            "degraded-90s", 90, 771,
            sweep_amplitude=1.25, loop_seconds=31.0, stationary=False,
            degraded_windows=[(18.0, 27.5, "insufficientFeatures"),
                              (52.0, 61.0, "relocalizing"),
                              (74.0, 78.0, "excessiveMotion")],
            dropout_windows=[(40.0, 40.9), (67.2, 67.6)],
            interruption=(33.0, 38.5),
            note=SHARED_NOTE + " Walks into a blank wall, loses tracking, is interrupted "
                 "by a phone call, and relocalises.")),
        ("trajectory-stationary-30s.json", build(
            "stationary-30s", 30, 4242,
            sweep_amplitude=0.85, loop_seconds=1e9, stationary=True,
            degraded_windows=[], dropout_windows=[], interruption=None,
            note=SHARED_NOTE + " A phone held roughly still and swept. Near-zero camera "
                 "baseline: no parallax, so no depth scale can be recovered from it.")),
    ]

    for filename, payload in specs:
        path = os.path.join(FIXTURES, filename)
        with open(path, "w") as handle:
            json.dump(payload, handle, separators=(",", ":"))
            handle.write("\n")
        written.append(path)
        print(f"{filename}: {len(payload['samples'])} samples, "
              f"{len(payload['markerEvents'])} marker events, "
              f"{os.path.getsize(path) / 1e6:.2f} MB")

    print("wrote:", ", ".join(os.path.relpath(p, REPO) for p in written))


if __name__ == "__main__":
    main()
