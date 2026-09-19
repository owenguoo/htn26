// 3D view of the room for the console: the scan (VGGT GLB, or the mock), everyone standing where
// they are with a cone showing where their camera points and its live feed at the end, the
// probability heatmap on the floor, sightings, the find and pings.
//
// Axes: three.js X = room x (right), Y = up, Z = room y (away from the stage). Meters throughout.
// Loaded on demand (console.js imports it the first time 3D is opened), so the 2D console never
// depends on three.js being reachable.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js';
import { CSS2DRenderer, CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';

const EYE_H = 1.45;      // phones are held about here
const FRUSTUM_M = 1.1;   // how far out the live feed floats
const FRAME_ASPECT = 4 / 3; // portrait frames: height / width

export function createScene3D(host, { room, getState, getThumb, onPick }) {
  const hfov = THREE.MathUtils.degToRad(room.cameraFovDeg);
  const vfov = 2 * Math.atan(Math.tan(hfov / 2) * FRAME_ASPECT);

  // ---- renderer, camera, controls
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.setClearColor(0x050505);
  renderer.localClippingEnabled = true;
  renderer.domElement.className = 's3d-canvas';
  host.appendChild(renderer.domElement);
  const labels = new CSS2DRenderer();
  labels.domElement.className = 's3d-labels';
  host.appendChild(labels.domElement);

  // Eye-Dome Lighting (as in point-cloud viewers like Potree): render into a target with a depth
  // texture, then darken each pixel by how much nearer its neighbors are. Edges and depth steps get
  // outlines, so a cloud of dots reads as solid walls and furniture.
  const rt = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, depthTexture: new THREE.DepthTexture(1, 1) });
  const edl = new THREE.ShaderMaterial({
    uniforms: {
      tColor: { value: rt.texture }, tDepth: { value: rt.depthTexture }, texel: { value: new THREE.Vector2() },
      near: { value: 0.1 }, far: { value: 200 }, strength: { value: 0.18 }, radius: { value: 1.4 },
    },
    vertexShader: 'varying vec2 vUv; void main() { vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }',
    fragmentShader: `
      uniform sampler2D tColor; uniform sampler2D tDepth; uniform vec2 texel;
      uniform float near; uniform float far; uniform float strength; uniform float radius;
      varying vec2 vUv;
      float logDepth(float d) { float z = d * 2.0 - 1.0; return log2((2.0 * near * far) / (far + near - z * (far - near))); }
      void main() {
        vec4 color = texture2D(tColor, vUv);
        float d0 = texture2D(tDepth, vUv).x;
        if (d0 >= 1.0) { gl_FragColor = color; }
        else {
          float l0 = logDepth(d0), sum = 0.0;
          for (int i = 0; i < 8; i++) {
            float a = float(i) * 0.785398;
            float dn = texture2D(tDepth, vUv + vec2(cos(a), sin(a)) * texel * radius).x;
            sum += dn >= 1.0 ? 0.0 : min(0.04, max(0.0, l0 - logDepth(dn)));
          }
          gl_FragColor = vec4(color.rgb * exp(-sum / 8.0 * 300.0 * strength), color.a);
        }
        #include <colorspace_fragment>
      }`,
    depthTest: false, depthWrite: false,
  });
  const post = new THREE.Scene();
  post.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), edl));
  const postCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(45, 1, 0.1, 200);
  camera.position.set(0, 13, room.depth + 11);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.target.set(0, 0, room.depth * 0.42);
  controls.enableDamping = true;
  controls.maxPolarAngle = Math.PI * 0.49;
  controls.minDistance = 0.15;
  controls.maxDistance = 60;
  controls.update();

  scene.add(new THREE.HemisphereLight(0xffffff, 0x222233, 1.6));
  const sun = new THREE.DirectionalLight(0xffffff, 1.2);
  sun.position.set(-6, 12, 8);
  scene.add(sun);

  // ---- the room: a faint outline (always), the scan on top when it loads
  const W = room.width / 2, D = room.depth, SD = room.stage.depth, SW = room.stage.width / 2;
  const outline = new THREE.LineSegments(
    new THREE.EdgesGeometry(new THREE.BoxGeometry(room.width, 4, D + SD).translate(0, 2, (D - SD) / 2)),
    new THREE.LineBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.12 }));
  scene.add(outline);
  const stage = new THREE.LineSegments(
    new THREE.EdgesGeometry(new THREE.BoxGeometry(SW * 2, 0.8, SD).translate(0, 0.4, -SD / 2)),
    new THREE.LineBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.2 }));
  scene.add(stage);

  // the scan: room.json's (the mock) until the live VGGT scan arrives, then each new version replaces it
  let scanStatus = 'none', scanObj = null, scanVersion = null, scanLabel = '';
  let heatMask = null; // which floor cells the live scan covers (the heatmap is only drawn there)
  const loader = new GLTFLoader();
  const draco = new DRACOLoader();
  draco.setDecoderPath('https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/libs/draco/gltf/');
  draco.setWorkerLimit(1);
  loader.setDRACOLoader(draco);
  let transformKey = '', fitted = false, cutaway = false;
  const cutPlane = new THREE.Plane(new THREE.Vector3(0, -1, 0), 0);

  const toolbar = document.createElement('div');
  toolbar.className = 's3d-tools';
  toolbar.innerHTML = '<button type="button" data-view="fit">Fit view</button><button type="button" data-view="top">Top view</button><button type="button" data-view="cut" aria-pressed="false">Cutaway</button><button type="button" data-view="heat" aria-pressed="false">Search heat</button>';
  host.appendChild(toolbar);
  toolbar.addEventListener('click', (e) => {
    const action = e.target.closest('button')?.dataset.view;
    if (action === 'fit' || action === 'top') fitView(action === 'top');
    if (action === 'heat') {
      heat.visible = !heat.visible;
      e.target.setAttribute('aria-pressed', String(heat.visible));
    }
    if (action === 'cut') {
      cutaway = !cutaway;
      e.target.setAttribute('aria-pressed', String(cutaway));
      updateCutaway();
    }
  });

  function fitView(top = false) {
    const bounds = scanObj ? new THREE.Box3().setFromObject(scanObj) : null;
    if (!bounds || bounds.isEmpty()) {
      camera.position.set(0, 13, room.depth + 11);
      controls.target.set(0, 0, room.depth * .42);
      return;
    }
    const center = bounds.getCenter(new THREE.Vector3());
    const radius = Math.max(bounds.getSize(new THREE.Vector3()).length() / 2, .1);
    const tanV = Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2), tanH = tanV * camera.aspect;
    const direction = new THREE.Vector3(top ? .001 : 1, top ? 1 : .85, top ? 0 : 1.2).normalize();
    const right = new THREE.Vector3().crossVectors(camera.up, direction).normalize();
    const up = new THREE.Vector3().crossVectors(direction, right);
    let distance = .1;
    for (const x of [bounds.min.x, bounds.max.x]) for (const y of [bounds.min.y, bounds.max.y]) for (const z of [bounds.min.z, bounds.max.z]) {
      const corner = new THREE.Vector3(x, y, z).sub(center), depth = corner.dot(direction);
      distance = Math.max(distance, depth + Math.abs(corner.dot(right)) / tanH, depth + Math.abs(corner.dot(up)) / tanV);
    }
    distance *= 1.1;
    controls.target.copy(center);
    camera.position.copy(center).addScaledVector(direction, distance);
    controls.minDistance = radius * .08;
    controls.maxDistance = distance * 6;
    camera.near = Math.max(.005, radius / 300);
    camera.far = Math.max(200, distance * 10);
    camera.updateProjectionMatrix();
    edl.uniforms.near.value = camera.near;
    edl.uniforms.far.value = camera.far;
    controls.update();
  }

  function updateCutaway() {
    if (!scanObj) return;
    const box = new THREE.Box3().setFromObject(scanObj);
    cutPlane.constant = box.min.y + (box.max.y - box.min.y) * .67;
    scanObj.traverse((o) => {
      if (!o.material) return;
      o.material.clippingPlanes = cutaway ? [cutPlane] : [];
      o.material.needsUpdate = true;
    });
  }

  // round points (not squares), sized to the scan's point spacing
  function scanMaterial(size) {
    const m = new THREE.PointsMaterial({ size, vertexColors: true, sizeAttenuation: true });
    m.onBeforeCompile = (sh) => {
      sh.fragmentShader = sh.fragmentShader.replace('#include <clipping_planes_fragment>',
        'vec2 pc = gl_PointCoord - 0.5; if (dot(pc, pc) > 0.25) discard;\n#include <clipping_planes_fragment>');
    };
    return m;
  }

  function dropScan(obj) {
    scene.remove(obj);
    obj.traverse((o) => { o.geometry?.dispose(); o.material?.dispose?.(); });
  }

  function applyTransform(obj, tf) {
    const s = tf.scale ?? 1;
    obj.scale.setScalar(s);
    obj.rotation.y = THREE.MathUtils.degToRad(tf.rotateYDeg ?? 0);
    obj.position.fromArray(tf.offset ?? [0, 0, 0]);
    obj.traverse((o) => { if (o.isPoints) o.material.size = o.userData.spacing * s; });
    obj.updateMatrixWorld(true);
    transformKey = JSON.stringify(tf);
  }

  function loadScan(url, tf, label, version, live) {
    scanStatus = scanObj ? scanStatus : 'loading';
    loader.load(url, (gltf) => {
      const obj = gltf.scene;
      if (version !== scanVersion) { dropScan(obj); return; }
      obj.userData.scanVersion = version;
      obj.traverse((o) => {
        if (!o.isPoints && !o.isMesh) return;
        if (o.isMesh && !live) return; // retain the mock scene's authored materials/textures
        o.material?.dispose?.();
        if (o.isPoints) {
          o.geometry.computeBoundingBox();
          const size = o.geometry.boundingBox.getSize(new THREE.Vector3());
          o.userData.spacing = Math.max(size.x, size.y, size.z) / 350 * 2;
          o.material = scanMaterial(o.userData.spacing);
        } else {
          // Captured RGB already includes the room's lighting. Relighting it blows out
          // pale walls and hides texture, so surfaces use the photograph's own color.
          o.material = new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.DoubleSide });
        }
      });
      // A fit adjustment can arrive while the file is loading.
      applyTransform(obj, live ? (getState()?.scan?.last?.transform ?? tf) : tf);
      if (scanObj) dropScan(scanObj);
      scene.add(obj);
      scanObj = obj;
      scanStatus = 'ready';
      scanLabel = label;
      outline.visible = stage.visible = !live;
      updateCutaway();
      if (!fitted) { fitView(); fitted = true; }
      heatMask = live ? footprint(obj) : null;
      heatKey = ''; // redraw the heatmap with the new mask
    }, undefined, () => { if (!scanObj) scanStatus = 'failed'; });
  }

  // floor cells (same grid as the coverage heatmap) that have scan points above them, grown by a cell
  function footprint(obj) {
    const cov = getState()?.coverage;
    if (!cov) return null;
    obj.updateMatrixWorld(true);
    const hit = new Uint8Array(cov.cols * cov.rows), v = new THREE.Vector3();
    obj.traverse((o) => {
      if (!o.isPoints && !o.isMesh) return;
      const pos = o.geometry.attributes.position;
      for (let i = 0; i < pos.count; i++) {
        v.fromBufferAttribute(pos, i).applyMatrix4(o.matrixWorld);
        if (v.y > 2.2) continue; // ceilings don't say where the floor is
        const c = Math.floor((v.x - cov.x0) / cov.cell), r = Math.floor(v.z / cov.cell);
        if (c >= 0 && r >= 0 && c < cov.cols && r < cov.rows) hit[r * cov.cols + c] = 1;
      }
    });
    const grown = new Uint8Array(hit.length); // 2 = scanned, 1 = the ring around it (drawn fainter, for a soft edge)
    for (let r = 0; r < cov.rows; r++) {
      for (let c = 0; c < cov.cols; c++) {
        if (!hit[r * cov.cols + c]) continue;
        grown[r * cov.cols + c] = 2;
        for (let dr = -1; dr <= 1; dr++) {
          for (let dc = -1; dc <= 1; dc++) {
            const rr = r + dr, cc = c + dc;
            if (rr >= 0 && cc >= 0 && rr < cov.rows && cc < cov.cols) grown[rr * cov.cols + cc] = Math.max(grown[rr * cov.cols + cc], 1);
          }
        }
      }
    }
    return grown;
  }

  function syncScan(st) {
    const live = st?.scan?.last;
    if (live && live.version !== scanVersion) {
      scanVersion = live.version;
      const a = live.alignment || {};
      loadScan(live.url, live.transform, `live scan v${live.version} · ${live.frames} views · ${a.method}`
        + (a.residualM != null ? ` (±${a.residualM} m)` : ''), live.version, true);
    } else if (live && scanObj?.userData.scanVersion === live.version && JSON.stringify(live.transform) !== transformKey) {
      applyTransform(scanObj, live.transform);
      heatMask = footprint(scanObj);
      heatKey = '';
      updateCutaway();
    } else if (!live && typeof scanVersion === 'number') {
      // the live scan was reset: clear it and wait for the next one
      scanVersion = null;
      if (scanObj) { dropScan(scanObj); scanObj = null; }
      heatMask = null;
      heatKey = '';
      scanStatus = 'waiting';
      fitted = false;
    } else if (!live && st?.scan?.enabled && scanVersion === 'room') {
      // live scanning is on: take the mock away and wait for the real thing
      scanVersion = null;
      if (scanObj) { dropScan(scanObj); scanObj = null; }
      scanStatus = 'waiting';
      fitted = false;
    } else if (!live && !st?.scan?.enabled && scanVersion === null && room.scene?.url) {
      scanVersion = 'room';
      loadScan(room.scene.url, room.scene, `mock scan: ${room.scene.url.split('/').pop()}`, 'room', false);
    }
  }

  // ---- probability heatmap on the floor (same data as the 2D map)
  const heatCanvas = document.createElement('canvas');
  const heatTex = new THREE.CanvasTexture(heatCanvas);
  heatTex.colorSpace = THREE.SRGBColorSpace;
  const heat = new THREE.Mesh(new THREE.PlaneGeometry(room.width, D),
    new THREE.MeshBasicMaterial({ map: heatTex, transparent: true, depthWrite: false }));
  heat.rotation.x = -Math.PI / 2;
  heat.position.set(0, 0.02, D / 2);
  heat.renderOrder = 1;
  heat.visible = false;
  scene.add(heat);
  let heatKey = '';

  function updateHeat(cov) {
    if (!cov?.heat || cov.heat === heatKey) return;
    if (heatMask && heatMask.length !== cov.heat.length) heatMask = null;
    // over a live scan the heat glows (adds light) instead of painting over the floor
    heat.material.blending = heatMask ? THREE.AdditiveBlending : THREE.NormalBlending;
    heat.material.needsUpdate = true;
    heatKey = cov.heat;
    heatCanvas.width = cov.cols;
    heatCanvas.height = cov.rows;
    const g = heatCanvas.getContext('2d');
    const img = g.createImageData(cov.cols, cov.rows);
    for (let i = 0; i < cov.heat.length; i++) {
      const v = parseInt(cov.heat[i], 36) / 35;
      // a light warm wash: likely areas glow, searched ones clear. Over a live scan it's fainter and
      // only where the scan has floor, so the room itself stays the thing you look at.
      img.data[i * 4] = 255;
      img.data[i * 4 + 1] = Math.round(60 + 110 * v);
      img.data[i * 4 + 2] = 30;
      img.data[i * 4 + 3] = heatMask ? Math.round(v * v * v * [0, 14, 34][heatMask[i]]) : Math.round(v * v * v * 70);
    }
    g.putImageData(img, 0, 0);
    heatTex.needsUpdate = true;
  }

  // ---- people
  const people = new Map(); // phone id → figure

  function makePerson(p) {
    const color = new THREE.Color(p.color || '#ffffff');
    const g = new THREE.Group();
    const mat = new THREE.MeshStandardMaterial({ color, roughness: 0.55, metalness: 0.05 });
    const body = new THREE.Mesh(new THREE.CapsuleGeometry(0.2, 0.8, 6, 12), mat);
    body.position.y = 0.2 + 0.4 + 0.2;
    const head = new THREE.Mesh(new THREE.SphereGeometry(0.14, 20, 14), mat);
    head.position.y = 1.62;
    const ring = new THREE.Mesh(new THREE.RingGeometry(0.32, 0.4, 40),
      new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.6, side: THREE.DoubleSide }));
    ring.rotation.x = -Math.PI / 2;
    ring.position.y = 0.03;
    g.add(body, head, ring);

    // camera: rotates with heading (Y) and pitch (X); points down its local -Z
    const cam = new THREE.Group();
    cam.position.y = EYE_H;
    cam.rotation.order = 'YXZ';
    const phone = new THREE.Mesh(new THREE.BoxGeometry(0.08, 0.15, 0.01),
      new THREE.MeshStandardMaterial({ color: 0x111111 }));
    phone.position.z = -0.3;
    const hw = FRUSTUM_M * Math.tan(hfov / 2), hh = FRUSTUM_M * Math.tan(vfov / 2);
    const corners = [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]].map(([x, y]) => new THREE.Vector3(x, y, -FRUSTUM_M));
    const apex = new THREE.Vector3(0, 0, -0.3);
    const coneGeo = new THREE.BufferGeometry().setFromPoints([
      apex, corners[0], apex, corners[1], apex, corners[2], apex, corners[3],
      corners[0], corners[1], corners[1], corners[2], corners[2], corners[3], corners[3], corners[0]]);
    const cone = new THREE.LineSegments(coneGeo, new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0.7 }));
    const faces = new THREE.BufferGeometry().setFromPoints([
      apex, corners[0], corners[1], apex, corners[1], corners[2], apex, corners[2], corners[3], apex, corners[3], corners[0]]);
    const fill = new THREE.Mesh(faces, new THREE.MeshBasicMaterial({
      color, transparent: true, opacity: 0.08, side: THREE.DoubleSide, depthWrite: false }));
    // live feed on the far end of the cone, facing back toward the person (reads correctly from behind)
    const img = new Image();
    const tex = new THREE.Texture(img);
    tex.colorSpace = THREE.SRGBColorSpace;
    img.onload = () => { tex.needsUpdate = true; video.visible = true; };
    const video = new THREE.Mesh(new THREE.PlaneGeometry(hw * 2, hh * 2),
      new THREE.MeshBasicMaterial({ map: tex, transparent: true, opacity: 0.95, side: THREE.DoubleSide }));
    video.position.z = -FRUSTUM_M;
    video.visible = false;
    cam.add(phone, cone, fill, video);
    g.add(cam);

    const tag = document.createElement('div');
    tag.className = 's3d-tag';
    const label = new CSS2DObject(tag);
    label.position.y = 2.05;
    g.add(label);

    g.traverse((o) => { o.userData.phoneId = p.id; });
    scene.add(g);
    return { g, cam, ring, img, tag, thumb: null, x: null, y: null, heading: 0, pitch: 0 };
  }

  // ---- markers: sightings, the find, pings
  const markers = new THREE.Group();
  scene.add(markers);
  const beamGeo = new THREE.CylinderGeometry(0.06, 0.06, 1, 12, 1, true).translate(0, 0.5, 0);
  const ringGeo = new THREE.RingGeometry(0.5, 0.62, 48);

  function beam(x, y, color, height, opacity, label, pulse) {
    const g = new THREE.Group();
    const b = new THREE.Mesh(beamGeo, new THREE.MeshBasicMaterial({ color, transparent: true, opacity, depthWrite: false }));
    b.scale.y = height;
    const r = new THREE.Mesh(ringGeo, new THREE.MeshBasicMaterial({ color, transparent: true, opacity, side: THREE.DoubleSide }));
    r.rotation.x = -Math.PI / 2;
    r.position.y = 0.04;
    r.userData.pulse = pulse;
    g.add(b, r);
    g.position.set(x, 0, y);
    if (label) {
      const el = document.createElement('div');
      el.className = 's3d-mark';
      el.textContent = label;
      el.style.color = `#${new THREE.Color(color).getHexString()}`;
      const l = new CSS2DObject(el);
      l.position.y = height + 0.25;
      g.add(l);
    }
    markers.add(g);
  }

  let markerKey = '';
  function updateMarkers(st) {
    const t = st.target;
    const sightings = t?.foundBy ? [] : (st.sightings || []).filter((s) => s.confidence >= 0.2);
    const key = JSON.stringify([t?.fix, t?.foundBy, sightings.map((s) => [s.x, s.y, s.confidence]),
      (st.pings || []).map((p) => p.id)]);
    if (key === markerKey) return;
    markerKey = key;
    for (const m of [...markers.children]) {
      m.traverse((o) => { if (o.element) o.element.remove(); });
      markers.remove(m);
    }
    if (t?.foundBy && t.fix) beam(t.fix[0], t.fix[1], 0xff4d5e, 6, 0.85, `FOUND · ${Math.round((t.confidence || 0) * 100)}%`, true);
    for (const s of sightings) {
      beam(s.x, s.y, 0xff4d5e, 1 + 3 * s.confidence, 0.25 + 0.5 * s.confidence,
        s.confidence >= 0.4 ? `possible · ${Math.round(s.confidence * 100)}%` : null, s.confidence >= 0.4);
    }
    for (const pg of st.pings || []) beam(pg.x, pg.y, 0xffb703, 3, 0.7, pg.label, true);
  }

  // ---- per frame
  const clock = new THREE.Clock();
  let running = false, frameId = null;

  function syncPeople(st) {
    const seen = new Set();
    for (const p of st.phones || []) {
      const pose = p.pose;
      if (!pose || !p.connected) continue;
      seen.add(p.id);
      let f = people.get(p.id);
      if (!f) { f = makePerson(p); people.set(p.id, f); }
      f.target = { x: pose.x, y: pose.y, heading: pose.heading ?? f.heading, pitch: p.pitch ?? 0 };
      const v = p.vision;
      f.tag.innerHTML = `<b style="color:${p.color}">#${p.index}</b> ${escapeHtml(p.name || '')}`
        + (p.caption ? `<div class="s3d-say">“${escapeHtml(p.caption.text)}”</div>` : '')
        + (v?.sees ? `<div class="s3d-sees${v.urgent || v.target ? ' hit' : ''}">👁 ${escapeHtml(v.sees)}</div>` : '');
      const url = getThumb(p.id);
      if (url && url !== f.thumb) { f.thumb = url; f.img.src = url; }
      const team = st.target?.responders && p.id in st.target.responders;
      f.ring.material.color.set(team ? 0xff4d5e : p.color);
    }
    for (const [id, f] of people) {
      if (seen.has(id)) continue;
      f.tag.remove();
      scene.remove(f.g);
      people.delete(id);
    }
  }

  function frame() {
    if (!running) return;
    frameId = requestAnimationFrame(frame);
    const dt = Math.min(0.1, clock.getDelta()), k = 1 - Math.exp(-dt * 8), t = clock.elapsedTime;
    const st = getState();
    syncScan(st);
    if (st) {
      syncPeople(st);
      updateHeat(st.coverage);
      updateMarkers(st);
    }
    for (const f of people.values()) {
      const tg = f.target;
      if (!tg) continue;
      if (f.x == null) { f.x = tg.x; f.y = tg.y; f.heading = tg.heading || 0; }
      f.x += (tg.x - f.x) * k;
      f.y += (tg.y - f.y) * k;
      f.heading += (((tg.heading - f.heading + 540) % 360) - 180) * k;
      f.pitch += (tg.pitch - f.pitch) * k;
      f.g.position.set(f.x, 0, f.y);
      // heading 0 faces the stage (-Z), clockwise from above; the camera looks down its local -Z
      f.cam.rotation.y = -THREE.MathUtils.degToRad(f.heading);
      f.cam.rotation.x = THREE.MathUtils.degToRad(Math.max(-80, Math.min(80, f.pitch)));
    }
    markers.traverse((o) => {
      if (o.userData.pulse) o.scale.setScalar(1 + 0.35 * (0.5 + 0.5 * Math.sin(t * 4)));
    });
    controls.update();
    renderer.setRenderTarget(rt);
    renderer.render(scene, camera);
    renderer.setRenderTarget(null);
    renderer.render(post, postCam);
    labels.render(scene, camera);
  }

  function resize() {
    const w = host.clientWidth, h = host.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    const pr = renderer.getPixelRatio();
    rt.setSize(Math.round(w * pr), Math.round(h * pr));
    edl.uniforms.texel.value.set(1 / (w * pr), 1 / (h * pr));
    labels.setSize(w, h);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  }
  new ResizeObserver(resize).observe(host);

  // click a person: open their feed
  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
  let down = null;
  renderer.domElement.addEventListener('pointerdown', (e) => { down = [e.clientX, e.clientY]; });
  renderer.domElement.addEventListener('pointerup', (e) => {
    if (!down || Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 4) return; // it was a drag
    const r = renderer.domElement.getBoundingClientRect();
    ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    const hit = ray.intersectObjects([...people.values()].map((f) => f.g), true)[0];
    if (hit?.object.userData.phoneId) onPick?.(hit.object.userData.phoneId);
  });

  return {
    show() { if (!running) { running = true; resize(); clock.getDelta(); frame(); } },
    hide() { running = false; cancelAnimationFrame(frameId); frameId = null; },
    status: () => scanStatus,
    label: () => scanLabel,
    resetView: () => fitView(),
  };
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
