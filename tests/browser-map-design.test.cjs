const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const html = fs.readFileSync('web/console.html', 'utf8');
const code = fs.readFileSync('web/console.js', 'utf8');

test('search map exposes a compact legend for its marker hierarchy', () => {
  assert.match(html, /class="map-legend"/);
  assert.match(html, />Searcher</);
  assert.match(html, />Possible sighting</);
  assert.match(html, />Found person</);
});

test('legend keys mirror the marker border and person treatments', () => {
  const key = html.match(/\.map-key\s*\{([^}]+)\}/)?.[1] ?? '';
  assert.match(html, /--map-marker-size:\s*20px; --map-marker-stroke:\s*2px/);
  assert.match(key, /border:\s*var\(--map-marker-stroke\) solid #fff/);
  assert.doesNotMatch(key, /0 0 0 3px/);
  assert.match(html, /\.map-key\.sighting, \.map-key\.rescued \{ background: #fff/);
  assert.match(html, /\.map-key\.sighting \{ color: #d97706; border-color: #d97706/);
  assert.match(html, /\.map-key\.rescued \{ color: var\(--red\); border-color: var\(--red\)/);
});

test('live people markers share one diameter, stroke, and label gap', () => {
  assert.match(code, /const MAP_MARKER_RADIUS = 10;/);
  assert.match(code, /const MAP_MARKER_STROKE = 2;/);
  assert.match(code, /const MAP_LABEL_GAP = 4;/);
  assert.match(code, /ctx\.arc\(0, 0, MAP_MARKER_RADIUS/);
  assert.match(code, /function personLabelY\(/);
});

test('search map replaces the cell grid with a soft probability field', () => {
  assert.match(code, /function drawCoverage\(/);
  assert.match(code, /grid: false/);
  assert.doesNotMatch(code, /fillRect\(px, py, s \+ 0\.5, s \+ 0\.5\)/);
});

test('map gives searchers, possible sightings, and the found person distinct markers', () => {
  assert.match(code, /function drawPhone\(/);
  assert.match(code, /function drawPersonGlyph\(/);
  assert.match(code, /POSSIBLE ·/);
  assert.match(code, /teamFull\(v\) \? 'RESCUED' : 'FOUND PERSON'/);
});

test('badges at the same map coordinate reserve non-overlapping slots', () => {
  const start = code.indexOf('function reserveMapLabel(');
  const end = code.indexOf('\nfunction drawMapLabel(', start);
  const fn = code.slice(start, end);
  const vm = require('node:vm');
  const context = vm.createContext({});
  vm.runInContext('const mapLabelRects=[]; const canvas={clientWidth:320,clientHeight:240};' + fn, context);
  const first = JSON.parse(vm.runInContext('JSON.stringify(reserveMapLabel(150, 80, 120))', context));
  const second = JSON.parse(vm.runInContext('JSON.stringify(reserveMapLabel(150, 80, 100))', context));
  assert.equal(first.y, 80);
  assert.ok(second.y + 9 + 3 <= first.y - 9 || second.y - 9 - 3 >= first.y + 9);
});
