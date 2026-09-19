# Phone camera demo

The demo runs YOLOE and OSNet on the server while your phone supplies camera frames through its browser.
No phone app or on-device model installation is needed.

## Start locally

```sh
uv sync --frozen --extra yolo --extra reid
uv run --no-sync beacon demo --device cpu --port 8765
```

Open `http://localhost:8765/demo` on the same computer.
The command prints a random demo access code and starts YOLOE with person matching enabled.
The underlying service API key stays on the server.
To reuse a code, set `SWARM_DEMO_CODE` to a random secret of at least 16 characters before starting.
Use `--device cuda:0` when running on your GPU host.

## Open from your phone

Phone browsers require HTTPS for camera access; a plain HTTP address on your local Wi-Fi is insufficient.
For temporary testing, run [Cloudflare Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) in another terminal:

```sh
cloudflared tunnel --url http://127.0.0.1:8765
```

This workspace also has a downloaded official macOS ARM64 binary at `.cache/tools/cloudflared`:

```sh
.cache/tools/cloudflared tunnel --url http://127.0.0.1:8765 --no-autoupdate
```

Open the printed `https://…trycloudflare.com/demo` address in Safari or Chrome on the phone.
Enter the demo access code separately; it is not embedded in the URL.
Keep the Mac awake and both the model server and tunnel running.
The temporary hostname stops working when the tunnel stops and changes when a new tunnel is created.
Camera frames travel through Cloudflare's HTTPS tunnel to the Mac; inference runs on the Mac.

## Try a search

1. Choose a reference photo showing the person's body and clothing.
2. If several people are detected, select the numbered person you want.
3. Select the back or front camera, tap **Start camera**, and allow camera access.
4. Green boxes show candidates reaching the similarity threshold; blue boxes show other people.
5. Use **Latest analyzed frame** to inspect the exact frame behind a result.
6. Tap **Stop** to stop capture, or **Clear reference** to remove the stored target.

Without a reference, the camera detects people but does not attempt identity matching.
The threshold starts at 0.70 as a test setting; it is not calibrated for your room or phone.
Higher values are stricter.
Similar outfits, changed clothes, poor lighting, and occlusion can confuse appearance matching.
This is not facial recognition or confirmed identification.

## Streaming and lifecycle

The browser samples the live video at up to two JPEG frames per second, with one request in flight at a time.
Frames are resized to a maximum 960-pixel long edge before upload.
Slower requests reduce the effective frame rate rather than accumulate a backlog.
Live video and detection results can differ in time, so use the analyzed snapshot to inspect box alignment.
Changing the reference stops capture; changing the threshold discards any result using the old threshold.
Stopping the camera aborts the pending browser request and stops its media tracks.
Capture also stops when the page goes into the background.

The browser session expires after eight hours and can access only its own target and person-detection requests.
References are stored as embeddings in server memory, with a limit of 32 targets shared with the API.
Use **Clear reference** when finished; server restart clears all reference embeddings.
The demo does not save received photos or camera frames to disk.
Refreshing the page preserves the reference embedding while the session and server remain valid, but the local photo preview must be uploaded again.
Keep the access code private and stop the tunnel when testing is finished.

## Verification

- Browser sign-in, real reference-photo upload, multi-person selection, and registration passed through the UI.
- The layout was inspected at a 390-pixel phone width with no horizontal overflow.
- Public HTTPS login and secure-cookie handling passed.
- Six sequential real-model frame requests through the tunnel returned three expected matches and three expected absent-target results, with 90-214 ms round trips on this Mac.
- The camera-loop tests cover one request in flight, stopping/aborting, stale reference versions, and threshold changes.
- Authentication tests cover default-disabled routes, target/phone scoping, cross-origin rejection, signed-cookie tampering, and expiry.
- The Python wheel includes the HTML, CSS, and JavaScript assets.

The physical phone camera and mobile Safari permission flow require a hands-on phone test.
The verified image stream uses sample frames, not a sustained capacity or cross-camera accuracy benchmark.

```sh
uv run --no-sync pytest -q -W error
node --test tests/demo_stream.test.cjs
```
