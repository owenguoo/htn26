# Joint live room reconstruction

The hub defaults to `MAP_MODE=joint`, with `MAP_JOINT_FRAMES=24` (bounded to 12–32).
`MAP_MODE=sections` preserves the previous incremental section experiment.

The connected-view selector keeps shared references, new views from
participating phones, and older coverage within the batch budget. Once the bank
is full, it targets 20 retained views and up to four new views per 24-view update;
shortest overlap paths may consume some of those slots. This avoids replacing
most of the visual evidence at once. Every accepted
update replaces the displayed surface with one jointly reconstructed mesh.
Shared camera positions from the preceding batch align the replacement into the
existing map frame. A robust fit requires at least 70% agreement and applies the
bounded residual check to that consensus; inconsistent updates leave the previous
result visible. This tolerates a few changed camera predictions without stacking
misplaced geometry.
Original GLBs are preserved. The offline consolidated layer is cleared only when
a successful joint result replaces it. Capture continues to collect new views
while the single reconstruction job runs; pending views feed the next selection.

Joint requests use a fusion resolution of 80 voxels per median scene depth,
compared with 128 in the section experiment. This bounds meshing cost and smooths
fine geometry. Existing multi-view depth validation and edge rejection remain
active. Worker requests without `voxelResolution` retain the original 128 setting.
Deploy `gpu/vggt_worker.py` to the dedicated quality worker before enabling this.

No new calibration UI, phone permissions, or phone app build is required.
This is a bounded room preview, not lossless accumulation: areas outside the
selected views may disappear, weakly observed surfaces can have holes, and
moving people can still produce artifacts. Failed registration is held rather
than silently reanchoring the map. Large rooms may exceed this view budget.

## Saved-scan measurements

On the existing A100 quality worker, using the saved 96-view archive:

| Selected views | Fusion resolution | Worker time | Request round trip |
| --- | --- | --- | --- |
| 24 | 128 | 24.5 s | 27.9 s |
| 32 | 128 | 51.4 s | 59.3 s |
| 24 | 80 | 10.7 s | 12.7 s |

The first actual hub rebuild with the selected 24/80 settings took 15.5 s.
These are individual measurements, not latency guarantees. Browser inspection
showed fewer layered wall surfaces, but substantial holes and less floor coverage
than the accumulated sections. This mode does not solve missing observations.
