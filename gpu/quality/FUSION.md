# Offline surface consolidation

`fuse_sections.py --input SNAPSHOT --output RESULT` consumes a saved `last.json`
and its section GLBs. Run in the GPU worker environment with Open3D, NumPy,
SciPy and DracoPy installed. It uses CPU geometry processing, not VGGT inference.

The pass applies bounded ICP corrections, downsamples oriented observations,
reconstructs a Poisson surface, trims unsupported geometry and smooths twice.
It preserves the original coordinate frame and writes `fused.glb` plus a report.
It never modifies input files. The current 17-section snapshot took 24.6 seconds.
This is not an automatic per-generation live job.

To install an inspected result, stop the hub, back up `web/models/live/last.json`,
copy the GLB into that directory as `clean-NAME.glb`, then call
`Mapper.install_consolidated(filename, through_version)` on the restored mapper.
First verify that the snapshot's source sections match the current manifest.
Restart the hub normally. Installation refuses an active reconstruction or an
outdated final section version. The console's Fused surface toggle compares the
result with all original sections; later live sections append to the fused base.
Reset discards the consolidated display state. Manual map fit applies to both views.

Fusion reduces small fragments and overlapping near-identical surfaces, but
cannot reliably fix large registration drift, missing observations or moving
people. It also softens detail. Inspect both views before installing a new result.
