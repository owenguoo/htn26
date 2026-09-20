# Whole-room VGGT live maps

`MAP_MODE=global` is the product path. Each update sends the complete bounded
visual keyframe archive (up to 96 views) to VGGT at 384px preprocessing resolution.
VGGT predicts cameras and depth jointly; the hub replaces the entire preview.
It does not stitch independent meshes or make early inferred cameras permanent
anchors. A first capture provides display placement; scale remains an estimate.

The worker checks cross-view depth agreement on a half-resolution grid and fuses
the original depth/color into a TSDF with voxel size medianDepth/64. This retained
room geometry in the 4245 comparison while avoiding expensive mesh decimation.
The old preview stays visible until the replacement is complete. Failed requests
leave it unchanged. Captured keyframes are checkpointed before inference, including
pending views. The worker rejects oversized requests rather than truncating them.

## Validation

Input: IMG_4245.MOV, 44.603 seconds, 134 frames extracted at 3fps.
The comparison page is `/web/trajectory-test.html` in the research worktree.
Research artifacts are local, not committed. `gpu/replay_global.py` exercises the
actual binary HTTP worker protocol using growing frame prefixes and writes both
GLBs and detailed timing JSON. No pose data is sent in global requests.

The first 88-view experiment used rectified images selected from the offline SfM
experiment. Complete worker times at 12/24/44/64/88 views were approximately
1.4/2.0/3.6/5.3/7.7 seconds on the existing A100, including HTTP within the pod.
88-view postprocessing fell from 14.1 seconds to 4.4 seconds in a cached-depth
comparison. These exclude phone capture cadence, Internet upload, and hub scheduling.
Final raw-video validation used 88 uniformly sampled frames from the entire clip,
without SfM or lens rectification. Worker times at 12/24/44/64/88 views were
0.9/1.8/3.6/5.5/8.0 seconds. All five updates completed. At 88 views, 85.6%
of predicted pixels passed cross-view support filtering. This is a consistency
measure, not a ground-truth accuracy claim. Visually, the main room and passage
remain coherent; unseen floor areas and surfaces around people remain incomplete.

The hub starts another update after six new accepted views, or ten seconds with
fewer pending views, with at least five seconds between attempts. Large updates
therefore arrive at roughly the inference/fusion runtime plus upload time; this
is incremental live updating, not video-rate reconstruction. Existing Beacon
clients work unchanged; no new phone build or shared-origin step is required.

Measured-pose fusion remains an isolated research experiment. On this video its
holes and distortions were visibly worse than coherent VGGT reconstruction, so it
is not the product path. The video has no ARKit telemetry and supplies no metric
ground truth. Unseen surfaces, moving people, and monocular scale remain limitations.
