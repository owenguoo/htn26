// 8th Wall world tracking (web SLAM): camera position in meters and rotation, in the browser.
// Engine: https://github.com/8thwall/8thwall (MIT). Docs: https://8thwall.org/docs/engine

const XR_SRC = 'https://cdn.jsdelivr.net/npm/@8thwall/engine-binary@1/dist/xr.js';

function loadEngine() {
  if (window.XR8) return Promise.resolve();
  return new Promise((resolve, reject) => {
    window.addEventListener('xrloaded', () => resolve(), { once: true });
    const s = document.createElement('script');
    s.src = XR_SRC;
    s.async = true;
    s.crossOrigin = 'anonymous';
    s.setAttribute('data-preload-chunks', 'slam');
    s.onerror = () => reject(new Error('Could not load the 8th Wall engine'));
    document.head.appendChild(s);
  });
}

export const slamDebug = { chunk: 'not loaded', cameraStatus: null, reason: null, exception: null, scale: null };

// Starts the camera + SLAM on `canvas`. 8th Wall owns the camera in this mode.
//   onUpdate(reality) — every processed frame: { position, rotation, trackingStatus, ... }
//   onRender()        — right after the camera feed is drawn; the only safe time to read the canvas

export async function startSlam(canvas, { scale = 'absolute', onUpdate, onRender, onStatus, onError }) {
  await loadEngine();
  const XR8 = window.XR8;
  // Full 6DoF tracking lives in the "slam" chunk; without it the engine only tracks rotation.
  try {
    await XR8.loadChunk('slam');
    slamDebug.chunk = 'loaded';
  } catch (e) {
    slamDebug.chunk = `failed: ${e?.message || e}`;
  }
  XR8.XrController.configure({ scale }); // 'absolute' = meters; 'responsive' = arbitrary units
  slamDebug.scale = scale;
  // Size the canvas ourselves: XR8.FullWindowCanvas also moves it to the end of <body>,
  // where it covers the page UI.
  const fit = () => { canvas.width = innerWidth; canvas.height = innerHeight; };
  fit();
  addEventListener('resize', fit);
  XR8.addCameraPipelineModules([
    XR8.GlTextureRenderer.pipelineModule(),
    XR8.XrController.pipelineModule(),
    {
      name: 'beacon',
      onUpdate: ({ processCpuResult }) => {
        const reality = processCpuResult?.reality;
        if (!reality) return;
        slamDebug.reason = reality.trackingReason ?? null;
        onUpdate(reality);
      },
      onRender: () => onRender?.(),
      onCameraStatusChange: ({ status }) => { slamDebug.cameraStatus = status; onStatus?.(status); },
      onException: (e) => { slamDebug.exception = String(e?.message || e); onError?.(e); },
    },
  ]);
  XR8.run({ canvas, allowedDevices: XR8.XrConfig.device().ANY });
}

// Direction the camera looks (its -Z axis) in SLAM world coordinates (y up).
export function cameraForward({ x, y, z, w }) {
  return [-2 * (x * z + w * y), -2 * (y * z - w * x), -(1 - 2 * (x * x + y * y))];
}
