// Exercise the real camera-loop code with deterministic media and delayed HTTP boundaries.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
const { setTimeout: delay } = require("node:timers/promises");

function harness() {
  const elements = new Map();
  const drawing = {
    drawImage() {},
    clearRect() {},
    strokeRect() {},
    fillRect() {},
    fillText() {},
    measureText() {
      return { width: 100 };
    },
  };
  function element() {
    return {
      hidden: false,
      value: "0.7",
      textContent: "",
      width: 640,
      height: 480,
      videoWidth: 640,
      videoHeight: 480,
      readyState: 4,
      listeners: {},
      addEventListener(name, callback) {
        this.listeners[name] = callback;
      },
      classList: { toggle() {}, add() {}, remove() {} },
      getContext() {
        return drawing;
      },
      play: async () => {},
      toBlob(callback) {
        callback(new Blob(["frame"], { type: "image/jpeg" }));
      },
      querySelectorAll() {
        return [];
      },
    };
  }
  const get = (id) => {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  };
  let stopped = 0;
  const track = {
    stop() {
      stopped++;
    },
    addEventListener() {},
  };
  const requests = [];
  const sandbox = {
    console,
    URLSearchParams,
    Blob,
    AbortController,
    performance,
    setTimeout,
    crypto: { randomUUID: () => "frame" },
    document: {
      getElementById: get,
      createElement: element,
      addEventListener() {},
    },
    window: { isSecureContext: true, addEventListener() {} },
    navigator: {
      mediaDevices: {
        getUserMedia: async () => ({
          getTracks: () => [track],
          getVideoTracks: () => [track],
        }),
      },
    },
    fetch: async (url, options) => {
      if (url === "/demo/session")
        return {
          ok: true,
          status: 200,
          json: async () => ({
            phone_id: "phone",
            target_id: "target",
            target_version: "version",
          }),
        };
      return new Promise((resolve, reject) => {
        requests.push({
          url,
          options,
          resolve: (data) =>
            resolve({ ok: true, status: 200, json: async () => data }),
        });
        options.signal.addEventListener("abort", () =>
          reject(Object.assign(new Error("aborted"), { name: "AbortError" })),
        );
      });
    },
  };
  vm.runInNewContext(
    fs.readFileSync(
      path.join(__dirname, "../src/swarm_sight/static/demo.js"),
      "utf8",
    ),
    sandbox,
  );
  return { get, requests, stopped: () => stopped };
}
async function until(condition) {
  for (let i = 0; i < 150; i++) {
    if (condition()) return;
    await delay(10);
  }
  throw new Error("Condition timed out");
}
const result = {
  target_version: "version",
  width: 640,
  height: 480,
  matched: true,
  candidates: [{ box: [10, 20, 100, 200], similarity: 0.95 }],
};

test("one frame in flight, correct results, and stop aborts without more frames", async () => {
  const h = harness();
  await delay(0);
  await h.get("start-camera").listeners.click();
  await until(() => h.requests.length === 1);
  await delay(40);
  assert.equal(h.requests.length, 1);
  h.requests[0].resolve(result);
  await until(() => h.get("best-score").textContent === "0.95");
  assert.equal(h.get("people-count").textContent, 1);
  await until(() => h.requests.length === 2);
  h.get("stop-camera").listeners.click();
  assert.equal(h.stopped(), 1);
  assert.equal(h.requests[1].options.signal.aborted, true);
  await delay(600);
  assert.equal(h.requests.length, 2);
  assert.equal(h.get("live-pill").textContent, "CAMERA OFF");
});

test("mismatched reference version stops camera instead of showing stale match", async () => {
  const h = harness();
  await delay(0);
  await h.get("start-camera").listeners.click();
  await until(() => h.requests.length === 1);
  h.requests[0].resolve({ ...result, target_version: "replaced" });
  await until(() => h.stopped() === 1);
  assert.match(h.get("camera-status").textContent, /Reference changed/);
  assert.equal(h.get("best-score").textContent, "–");
});

test("changing threshold discards the pending result", async () => {
  const h = harness();
  await delay(0);
  await h.get("start-camera").listeners.click();
  await until(() => h.requests.length === 1);
  h.get("threshold").value = "0.95";
  h.get("threshold").listeners.input();
  h.requests[0].resolve(result);
  await delay(30);
  assert.equal(h.get("best-score").textContent, "–");
  h.get("stop-camera").listeners.click();
});
