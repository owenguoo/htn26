"use strict";
const $ = (id) => document.getElementById(id);
let session,
  targetVersion = null,
  stream = null,
  run = 0,
  activeRequest = null;
let referenceBusy = false;
const capture = document.createElement("canvas");
const context = capture.getContext("2d");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function status(id, text, error = false) {
  $(id).textContent = text;
  $(id).classList.toggle("error", error);
}
async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    ...options,
  });
  if (!response.ok) {
    let detail;
    try {
      detail = (await response.json()).detail;
    } catch {
      /* A proxy can return a non-JSON error. */
    }
    const error = new Error(
      typeof detail === "string"
        ? detail
        : `Request failed (${response.status}). Please try again.`,
    );
    error.status = response.status;
    throw error;
  }
  return response.status === 204 ? null : response.json();
}
function frameQuery(extra = {}) {
  return new URLSearchParams({
    phone_id: session.phone_id,
    frame_id: crypto.randomUUID(),
    captured_at: Date.now() / 1000,
    ...extra,
  });
}
function jpeg(canvas) {
  return new Promise((resolve, reject) =>
    canvas.toBlob(
      (blob) =>
        blob ? resolve(blob) : reject(new Error("Could not read the image.")),
      "image/jpeg",
      0.85,
    ),
  );
}
function paint(canvas, boxes, selected = -1, threshold = null) {
  const ctx = canvas.getContext("2d");
  const fontSize = Math.max(14, Math.round(canvas.width / 40));
  ctx.font = `600 ${fontSize}px system-ui`;
  ctx.lineWidth = Math.max(2, canvas.width / 220);
  boxes.forEach((item, index) => {
    const [x1, y1, x2, y2] = item.box;
    const match = threshold !== null && item.similarity >= threshold;
    const color = match || selected === index ? "#c4f088" : "#7dbbe0";
    ctx.strokeStyle = color;
    ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
    const text =
      threshold !== null
        ? `${match ? "Likely match" : "Person"} · ${item.similarity.toFixed(2)}`
        : `Person ${index + 1}`;
    const w = ctx.measureText(text).width + 12,
      h = fontSize + 12;
    const x = Math.max(0, Math.min(x1, canvas.width - w)),
      y = Math.max(0, y1 - h);
    ctx.fillStyle = color;
    ctx.fillRect(x, y, w, h);
    ctx.fillStyle = "#101b13";
    ctx.fillText(text, x + 6, y + fontSize + 3);
  });
}
function resetResults() {
  for (const id of ["people-count", "best-score", "latency"])
    $(id).textContent = "–";
  const overlay = $("overlay");
  overlay.getContext("2d").clearRect(0, 0, overlay.width, overlay.height);
  const result = $("result-frame");
  result.getContext("2d").clearRect(0, 0, result.width, result.height);
}
async function connect() {
  session = await api("/demo/session");
  targetVersion = session.target_version;
  $("login-panel").hidden = true;
  $("workspace").hidden = false;
  $("clear-reference").hidden = !targetVersion;
  status(
    "reference-status",
    targetVersion
      ? "Your reference is still registered. Upload again to preview or change it."
      : "No reference selected.",
  );
}
$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = event.currentTarget.querySelector("button");
  button.disabled = true;
  try {
    await api("/demo/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: $("code").value }),
    });
    $("code").value = "";
    await connect();
  } catch (error) {
    status("login-status", error.message, true);
  } finally {
    button.disabled = false;
  }
});

function setReferenceBusy(value) {
  referenceBusy = value;
  $("reference-file").disabled = value;
  $("clear-reference").disabled = value;
  $("start-camera").disabled = value || !!stream;
  $("person-choices")
    .querySelectorAll("button")
    .forEach((button) => (button.disabled = value));
}
$("reference-file").addEventListener("change", async () => {
  const file = $("reference-file").files[0];
  if (!file) return;
  stopCamera();
  setReferenceBusy(true);
  resetResults();
  $("person-choices").replaceChildren();
  status("reference-status", "Finding people in the reference photo…");
  try {
    if (file.size > 25_000_000)
      throw new Error("Choose a photo smaller than 25 MB.");
    const image = new Image(),
      url = URL.createObjectURL(file);
    try {
      image.src = url;
      await image.decode();
    } finally {
      URL.revokeObjectURL(url);
    }
    const photo = document.createElement("canvas");
    const scale = Math.min(
      1,
      1280 / Math.max(image.naturalWidth, image.naturalHeight),
    );
    photo.width = Math.max(1, Math.round(image.naturalWidth * scale));
    photo.height = Math.max(1, Math.round(image.naturalHeight * scale));
    photo.getContext("2d").drawImage(image, 0, 0, photo.width, photo.height);
    const blob = await jpeg(photo);
    const result = await api(`/v1/detect?${frameQuery({ labels: "person" })}`, {
      method: "POST",
      headers: { "Content-Type": "image/jpeg" },
      body: blob,
    });
    const preview = $("reference-preview");
    preview.width = photo.width;
    preview.height = photo.height;
    preview.hidden = false;
    preview.getContext("2d").drawImage(photo, 0, 0);
    paint(preview, result.detections);
    const choose = async (index) => {
      stopCamera();
      setReferenceBusy(true);
      status("reference-status", "Saving this person's appearance…");
      try {
        const params = new URLSearchParams();
        result.detections[index].box.forEach((coordinate) =>
          params.append("box", coordinate),
        );
        const registered = await api(
          `/v1/targets/${session.target_id}?${params}`,
          {
            method: "PUT",
            headers: { "Content-Type": "image/jpeg" },
            body: blob,
          },
        );
        targetVersion = registered.target_version;
        preview.getContext("2d").drawImage(photo, 0, 0);
        paint(preview, result.detections, index);
        $("person-choices")
          .querySelectorAll("button")
          .forEach((button, i) =>
            button.classList.toggle("selected", index === i),
          );
        $("clear-reference").hidden = false;
        resetResults();
        status(
          "reference-status",
          `Person ${index + 1} is your reference. Ready to search.`,
        );
      } catch (error) {
        status(
          "reference-status",
          `${error.message} Previous reference is unchanged.`,
          true,
        );
      } finally {
        setReferenceBusy(false);
      }
    };
    result.detections.forEach((_, index) => {
      const button = document.createElement("button");
      button.textContent = `Person ${index + 1}`;
      button.className = "secondary";
      button.addEventListener("click", () => choose(index));
      $("person-choices").append(button);
    });
    if (result.detections.length === 1) await choose(0);
    else
      status(
        "reference-status",
        result.detections.length
          ? targetVersion
            ? "Choose a numbered person to replace your current reference."
            : "Choose a numbered person to set the reference."
          : "No person found. Try a clearer, full-body photo.",
        !result.detections.length,
      );
  } catch (error) {
    status(
      "reference-status",
      `Could not use this photo: ${error.message}`,
      true,
    );
  } finally {
    setReferenceBusy(false);
    $("reference-file").value = "";
  }
});
$("clear-reference").addEventListener("click", async () => {
  stopCamera();
  setReferenceBusy(true);
  try {
    await api(`/v1/targets/${session.target_id}`, { method: "DELETE" });
    targetVersion = null;
    $("reference-preview").hidden = true;
    $("clear-reference").hidden = true;
    $("person-choices").replaceChildren();
    resetResults();
    status(
      "reference-status",
      "Reference cleared. Camera can still detect people.",
    );
  } catch (error) {
    status("reference-status", error.message, true);
  } finally {
    setReferenceBusy(false);
  }
});

function stopCamera() {
  run++;
  activeRequest?.abort();
  activeRequest = null;
  stream?.getTracks().forEach((track) => track.stop());
  stream = null;
  $("video").srcObject = null;
  $("video").hidden = true;
  $("overlay").hidden = true;
  $("camera-placeholder").hidden = false;
  $("start-camera").disabled = referenceBusy;
  $("stop-camera").disabled = true;
  $("camera-facing").disabled = false;
  $("live-pill").textContent = "CAMERA OFF";
  $("live-pill").classList.remove("active");
  status("camera-status", "Camera stopped. No frames are being sent.");
}
async function streamFrames(generation) {
  while (stream && run === generation) {
    const started = performance.now(),
      version = targetVersion;
    const video = $("video");
    if (!video.videoWidth || video.readyState < 2) {
      await sleep(100);
      continue;
    }
    const scale = Math.min(
      1,
      960 / Math.max(video.videoWidth, video.videoHeight),
    );
    capture.width = Math.round(video.videoWidth * scale);
    capture.height = Math.round(video.videoHeight * scale);
    context.drawImage(video, 0, 0, capture.width, capture.height);
    const threshold = Number($("threshold").value);
    try {
      const blob = await jpeg(capture);
      if (run !== generation) return;
      activeRequest = new AbortController();
      const params = frameQuery(
        version
          ? { target_id: session.target_id, similarity_threshold: threshold }
          : { labels: "person" },
      );
      const result = await api(
        `/v1/${version ? "match" : "detect"}?${params}`,
        {
          method: "POST",
          headers: { "Content-Type": "image/jpeg" },
          body: blob,
          signal: activeRequest.signal,
        },
      );
      if (run !== generation || version !== targetVersion) return;
      if (version && result.target_version !== version)
        throw new Error(
          "Reference changed. Reload the demo before continuing.",
        );
      if (version && threshold !== Number($("threshold").value)) {
        await sleep(Math.max(0, 500 - (performance.now() - started)));
        continue;
      }
      const boxes = result.candidates || result.detections;
      const overlay = $("overlay");
      overlay.width = result.width;
      overlay.height = result.height;
      const snapshot = $("result-frame");
      snapshot.width = capture.width;
      snapshot.height = capture.height;
      snapshot.getContext("2d").drawImage(capture, 0, 0);
      paint(overlay, boxes, -1, version ? threshold : null);
      paint(snapshot, boxes, -1, version ? threshold : null);
      $("people-count").textContent = boxes.length;
      $("best-score").textContent =
        version && boxes.length ? boxes[0].similarity.toFixed(2) : "–";
      $("latency").textContent =
        `${Math.round(performance.now() - started)} ms`;
      status(
        "camera-status",
        version
          ? result.matched
            ? "Likely match found. Check the highlighted person."
            : "Searching. No person meets your threshold."
          : "Detecting people. Add a reference photo to find a match.",
      );
    } catch (error) {
      if (run !== generation || error.name === "AbortError") return;
      resetResults();
      if (error.status === 401 || error.status === 404 || !error.status) {
        stopCamera();
        status("camera-status", error.message, true);
        return;
      }
      status(
        "camera-status",
        `${error.message} Retrying with a fresh frame…`,
        true,
      );
      await sleep(1000);
    }
    await sleep(Math.max(0, 500 - (performance.now() - started)));
  }
}
$("start-camera").addEventListener("click", async () => {
  if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
    status(
      "camera-status",
      "Phone cameras need HTTPS. Open the secure demo link, not this computer's local IP address.",
      true,
    );
    return;
  }
  const generation = ++run;
  $("start-camera").disabled = true;
  $("stop-camera").disabled = false;
  status("camera-status", "Waiting for camera permission…");
  try {
    const media = await navigator.mediaDevices.getUserMedia({
      video: {
        facingMode: { ideal: $("camera-facing").value },
        width: { ideal: 1280 },
        height: { ideal: 720 },
      },
      audio: false,
    });
    if (run !== generation) {
      media.getTracks().forEach((track) => track.stop());
      return;
    }
    stream = media;
    $("video").srcObject = media;
    await $("video").play();
    if (run !== generation) return;
    $("video").hidden = false;
    $("overlay").hidden = false;
    $("camera-placeholder").hidden = true;
    $("camera-facing").disabled = true;
    $("live-pill").textContent = "● LIVE";
    $("live-pill").classList.add("active");
    media.getVideoTracks()[0].addEventListener("ended", () => {
      if (run === generation) stopCamera();
    });
    streamFrames(generation);
  } catch (error) {
    if (run === generation) {
      stopCamera();
      status(
        "camera-status",
        `Camera could not start: ${error.message}. Check browser permissions.`,
        true,
      );
    }
  }
});
$("stop-camera").addEventListener("click", stopCamera);
$("threshold").addEventListener("input", () => {
  $("threshold-value").textContent = Number($("threshold").value).toFixed(2);
  resetResults();
  if (stream)
    status("camera-status", "Threshold updated. Waiting for a fresh result…");
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) stopCamera();
});
window.addEventListener("pagehide", stopCamera);
connect().catch(() => {});
