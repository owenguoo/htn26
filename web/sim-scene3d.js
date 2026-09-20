// 3D view of a simulated search: the floor plan stood up as walls (or the scan it was traced from),
// the search map on the floor, rescuers with their view cones, and the casualty.
//
// Axes as scene3d.js: three.js X = plan x, Y = up, Z = plan y. Meters throughout. Loaded on demand
// (simulator.js imports it the first time 3D is opened), so the plan view never needs three.js.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js';
import { CSS2DRenderer, CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';

const EYE_H = 1.45, CONE_M = 1.6, FURNITURE_H = 0.8, CUT_H = 1.1;
const GREEN = 0x18834b, AMBER = 0xd97706, RED = 0xb72f36;

export function createSimScene(host) {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.setClearColor(0xf5faf6);
  renderer.domElement.className = 's3d-canvas';
  host.appendChild(renderer.domElement);
  const labels = new CSS2DRenderer();
  labels.domElement.className = 's3d-labels';
  host.appendChild(labels.domElement);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(45, 1, 0.1, 400);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.maxPolarAngle = Math.PI * 0.49;
  scene.add(new THREE.HemisphereLight(0xffffff, 0x9fb5a7, 1.7));
  const sun = new THREE.DirectionalLight(0xffffff, 1.1);
  sun.position.set(-8, 16, 6);
  scene.add(sun);

  const toolbar = document.createElement('div');
  toolbar.className = 's3d-tools';
  toolbar.innerHTML = '<button type="button" data-view="fit">Fit view</button><button type="button" data-view="top">Top view</button>'
    + '<button type="button" data-view="cut" aria-pressed="true">Cutaway</button><button type="button" data-view="scan" aria-pressed="true" hidden>Scan</button>';
  host.appendChild(toolbar);

  let env = null, building = null, scanObj = null, cutaway = true, showScan = true;
  let walls = null, heatTex = null, heatMesh = null, flames = null;
  const flameMatrix = new THREE.Matrix4();
  const loader = new GLTFLoader();
  const draco = new DRACOLoader();
  draco.setDecoderPath('https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/libs/draco/gltf/');
  loader.setDRACOLoader(draco);

  toolbar.addEventListener('click', (e) => {
    const action = e.target.closest('button')?.dataset.view;
    if (action === 'fit' || action === 'top') fit(action === 'top');
    if (action === 'cut') { cutaway = !cutaway; e.target.setAttribute('aria-pressed', String(cutaway)); applyCut(); }
    if (action === 'scan') { showScan = !showScan; e.target.setAttribute('aria-pressed', String(showScan)); applyCut(); }
  });

  function dispose(obj) {
    obj.traverse((o) => { o.element?.remove(); o.geometry?.dispose(); if (o.material) { o.material.map?.dispose(); o.material.dispose(); } });
    obj.removeFromParent();
  }

  function boxes(cells, height, color, opacity = 1) {
    const mesh = new THREE.InstancedMesh(new THREE.BoxGeometry(env.cell, 1, env.cell),
      new THREE.MeshStandardMaterial({ color, roughness: .9, transparent: opacity < 1, opacity }), cells.length);
    const m = new THREE.Matrix4();
    cells.forEach(([r, c], i) => {
      m.makeScale(1, height, 1).setPosition((c + .5) * env.cell, height / 2, (r + .5) * env.cell);
      mesh.setMatrixAt(i, m);
    });
    return mesh;
  }

  function setEnv(next) {
    if (!next || next === env) return;
    env = next;
    if (building) dispose(building);
    for (const f of team.values()) dispose(f.g);
    team.clear();
    building = new THREE.Group();
    scanObj = null;
    const wallCells = [], lowCells = [], fireCells = [], smokeCells = [];
    const floorShape = document.createElement('canvas');
    floorShape.width = env.cols; floorShape.height = env.rows;
    const g = floorShape.getContext('2d');
    env.cells.forEach((row, r) => row.forEach((ch, c) => {
      if (ch === '#') wallCells.push([r, c]);
      if (ch === 'o') lowCells.push([r, c]);
      if (ch === 'f') fireCells.push([r, c]);
      if (ch === 's' || ch === '~') smokeCells.push([r, c]);
      if (ch !== ' ') { g.fillStyle = ch === '_' ? '#e3ebe6' : '#ffffff'; g.fillRect(c, r, 1, 1); }
    }));
    const plane = () => new THREE.PlaneGeometry(env.width, env.depth).rotateX(-Math.PI / 2).translate(env.width / 2, 0, env.depth / 2);
    const floorTex = new THREE.CanvasTexture(floorShape);
    floorTex.magFilter = THREE.NearestFilter; floorTex.colorSpace = THREE.SRGBColorSpace;
    building.add(new THREE.Mesh(plane(), new THREE.MeshBasicMaterial({ map: floorTex, transparent: true })));
    heatTex = new THREE.CanvasTexture(document.createElement('canvas'));
    heatTex.colorSpace = THREE.SRGBColorSpace;
    heatMesh = new THREE.Mesh(plane(), new THREE.MeshBasicMaterial({ map: heatTex, transparent: true, depthWrite: false }));
    heatMesh.position.y = 0.08; heatMesh.visible = false;  // clear of a scanned floor's bumps
    building.add(heatMesh);
    walls = new THREE.Group();
    walls.add(boxes(wallCells, 1, 0x5d7d69), boxes(lowCells, FURNITURE_H, 0xc9ddd0));
    building.add(walls);
    // hazards: fire glows and flickers (render()); smoke is a gray haze you can see rescuers through
    flames = null;
    if (fireCells.length) {
      flames = new THREE.InstancedMesh(new THREE.ConeGeometry(env.cell * .6, 1, 7).translate(0, .5, 0),
        new THREE.MeshBasicMaterial({ color: 0xff7a1a, transparent: true, opacity: .85 }), fireCells.length);
      flames.userData.cells = fireCells;
      building.add(boxes(fireCells, .06, 0xe4572e), flames);
    }
    if (smokeCells.length) {
      const haze = boxes(smokeCells, 2.2, 0x6f7a74, .12);
      haze.material.depthWrite = false;
      haze.renderOrder = 2;
      building.add(haze);
    }
    for (const room of env.rooms || []) building.add(tag(room.name, 's3d-room', room.x, 0.1, room.y));
    for (const e of env.entryPoints) {
      const post = new THREE.Mesh(new THREE.CylinderGeometry(.12, .12, 2.2, 12), new THREE.MeshBasicMaterial({ color: 0x6b4fbb }));
      post.position.set(e.x, 1.1, e.y);
      building.add(post, tag(e.name, 's3d-tag', e.x, 2.5, e.y));
    }
    scene.add(building);
    toolbar.querySelector('[data-view="scan"]').hidden = !env.scan;
    if (env.scan) loadScan(env);
    applyCut();
    fit();
  }

  function loadScan(forEnv) {
    loader.load(forEnv.scan.url, (gltf) => {
      if (env !== forEnv) return;
      scanObj = gltf.scene;
      scanObj.traverse((o) => {
        // captured color already has the room's light in it (as scene3d.js)
        if (o.isMesh && o.geometry.attributes.color && !o.material.map) o.material = new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.DoubleSide });
        else if (o.isMesh) o.material.side = THREE.DoubleSide;
        if (o.isPoints) o.material = new THREE.PointsMaterial({ size: 0.03, vertexColors: true });
      });
      scanObj.scale.setScalar(forEnv.scan.scale ?? 1);
      scanObj.rotation.y = THREE.MathUtils.degToRad(forEnv.scan.rotateYDeg ?? 0);
      scanObj.position.fromArray(forEnv.scan.offset ?? [0, 0, 0]);
      building.add(scanObj);
      applyCut();
    }, undefined, () => { toolbar.querySelector('[data-view="scan"]').hidden = true; });
  }

  // Cutaway: walls stop at waist height so you can see into every room; the scan is clipped the same way.
  const cutPlane = new THREE.Plane(new THREE.Vector3(0, -1, 0), CUT_H + .4);
  renderer.localClippingEnabled = true;
  function applyCut() {
    if (!env) return;
    const scanShown = !!scanObj && showScan;
    walls.visible = !scanShown;
    walls.children[0].scale.y = cutaway ? CUT_H : env.wallHeightM;
    if (scanObj) {
      scanObj.visible = scanShown;
      scanObj.traverse((o) => { if (o.material) { o.material.clippingPlanes = cutaway ? [cutPlane] : []; o.material.needsUpdate = true; } });
    }
  }

  function fit(top = false) {
    if (!env) return;
    resize();
    const center = new THREE.Vector3(env.width / 2, 0, env.depth / 2);
    const tanV = Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2);
    const span = Math.max(env.depth, env.width / Math.max(.1, camera.aspect));
    const distance = span / 2 / tanV * 1.15;
    const direction = top ? new THREE.Vector3(0, 1, .001) : new THREE.Vector3(0, .9, .75).normalize();
    controls.target.copy(center);
    camera.position.copy(center).addScaledVector(direction, top ? distance : distance * 1.1);
    controls.maxDistance = distance * 5;
    controls.update();
  }

  function tag(text, className, x, y, z) {
    const el = document.createElement('div');
    el.className = className; el.textContent = text;
    const o = new CSS2DObject(el);
    o.position.set(x, y, z);
    return o;
  }

  // ---- rescuers
  const team = new Map();
  function makeRescuer(i) {
    const g = new THREE.Group();
    const mat = new THREE.MeshStandardMaterial({ color: GREEN, roughness: .55 });
    const body = new THREE.Mesh(new THREE.CapsuleGeometry(.2, .8, 6, 12), mat);
    body.position.y = .8;
    const head = new THREE.Mesh(new THREE.SphereGeometry(.14, 20, 14), mat);
    head.position.y = 1.62;
    const cam = new THREE.Group();
    cam.position.y = EYE_H;
    const half = THREE.MathUtils.degToRad(env.fovDeg / 2), hw = CONE_M * Math.tan(half), hh = hw * .75;
    const apex = new THREE.Vector3(0, 0, -.2);
    const corners = [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]].map(([x, y]) => new THREE.Vector3(x, y, -CONE_M));
    const coneMat = new THREE.MeshBasicMaterial({ color: GREEN, transparent: true, opacity: .14, side: THREE.DoubleSide, depthWrite: false });
    cam.add(new THREE.Mesh(new THREE.BufferGeometry().setFromPoints([
      apex, corners[0], corners[1], apex, corners[1], corners[2], apex, corners[2], corners[3], apex, corners[3], corners[0]]), coneMat));
    cam.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints([
      apex, corners[0], apex, corners[1], apex, corners[2], apex, corners[3],
      corners[0], corners[1], corners[1], corners[2], corners[2], corners[3], corners[3], corners[0]]),
      new THREE.LineBasicMaterial({ color: GREEN, transparent: true, opacity: .6 })));
    g.add(body, head, cam, tag(`#${i + 1}`, 's3d-tag', 0, 2.05, 0));
    scene.add(g);
    return { g, cam, mat };
  }

  // ---- casualty
  const marker = new THREE.Group();
  const beamMat = new THREE.MeshBasicMaterial({ color: RED, transparent: true, opacity: .8, depthWrite: false });
  const beam = new THREE.Mesh(new THREE.CylinderGeometry(.06, .06, 3, 12, 1, true).translate(0, 1.5, 0), beamMat);
  const ring = new THREE.Mesh(new THREE.RingGeometry(.45, .58, 48).rotateX(-Math.PI / 2), beamMat);
  ring.position.y = .04;
  const lying = new THREE.Mesh(new THREE.CapsuleGeometry(.18, .9, 6, 12).rotateZ(Math.PI / 2),
    new THREE.MeshStandardMaterial({ color: 0x8a958e, roughness: .7 }));
  lying.position.y = .2;
  const markerTag = tag('', 's3d-tag', 0, 1.0, 0);
  marker.add(beam, ring, lying, markerTag);
  marker.visible = false;
  scene.add(marker);

  let running = false;
  function render(state) {
    if (!running || !env) return;
    const seen = new Set();
    for (const a of state.team || []) {
      seen.add(a.i);
      let f = team.get(a.i);
      if (!f) { f = makeRescuer(a.i); team.set(a.i, f); }
      f.g.position.set(a.x, 0, a.y);
      f.cam.rotation.y = -THREE.MathUtils.degToRad(a.heading);  // heading 0 looks down -Z, clockwise from above
      f.cam.visible = !a.responding;
      f.mat.color.set(a.responding ? AMBER : GREEN);
    }
    for (const [i, f] of team) if (!seen.has(i)) { dispose(f.g); team.delete(i); }
    heatMesh.visible = !!state.heat;
    if (state.heat && (state.heatChanged || heatTex.image !== state.heat)) { heatTex.image = state.heat; heatTex.needsUpdate = true; }
    marker.visible = !!state.casualty;
    if (state.casualty) {
      marker.position.set(state.casualty.x, 0, state.casualty.y);
      beam.visible = ring.visible = state.found;
      ring.scale.setScalar(1 + .3 * (.5 + .5 * Math.sin(performance.now() / 250)));
      markerTag.element.textContent = state.rescued ? 'RESCUED' : state.found ? 'FOUND' : 'Casualty';
      markerTag.element.classList.toggle('hot', state.found);
    }
    if (flames) {
      const t = performance.now() / 180;
      flames.userData.cells.forEach(([r, c], i) => {
        const h = .9 + .5 * Math.sin(t + r * 1.7 + c * 2.3) + .25 * Math.sin(t * 2.1 + c);
        flameMatrix.makeScale(1, h, 1).setPosition((c + .5) * env.cell, 0, (r + .5) * env.cell);
        flames.setMatrixAt(i, flameMatrix);
      });
      flames.instanceMatrix.needsUpdate = true;
    }
    controls.update();
    renderer.render(scene, camera);
    labels.render(scene, camera);
  }

  function resize() {
    const w = host.clientWidth, h = host.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    labels.setSize(w, h);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  }
  new ResizeObserver(resize).observe(host);
  host.addEventListener('dblclick', () => fit());

  return {
    setEnv,
    show() { running = true; resize(); fit(); },
    hide() { running = false; },
    render,
  };
}
