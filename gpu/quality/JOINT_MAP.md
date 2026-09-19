# Joint live room reconstruction

The hub defaults to `MAP_MODE=joint`, with `MAP_JOINT_FRAMES=24` (bounded to 12–32).
`MAP_MODE=sections` preserves the previous incremental section experiment.

The existing connected-view selector keeps shared references, new views from
participating phones, and older coverage within the batch budget. Every accepted
update replaces the displayed surface with one jointly reconstructed mesh.
Shared camera positions from the preceding batch align the replacement into the
existing map frame; inconsistent updates leave the previous result visible.
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
