const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const context = vm.createContext({});
const source = fs.readFileSync('web/rehearsal-scenarios.js', 'utf8')
  .replaceAll('export ', '')
  .replace('const REHEARSAL_SCENARIOS', 'globalThis.REHEARSAL_SCENARIOS');
vm.runInContext(source, context);
const run = expression => vm.runInContext(expression, context);

test('scenario anchor is the first connected phone with a calibrated heading', () => {
  const result = run(`rehearsalAnchor([
    {index: 1, connected: false, pose: {heading: 0}},
    {index: 4, connected: true, pose: {heading: null}},
    {index: 3, connected: true, pose: {heading: 90}},
    {index: 2, connected: true, pose: {heading: 180}}
  ]).index`);
  assert.equal(result, 2);
});

test('bearing scenarios use the phone heading and room coordinate system', () => {
  run('globalThis.room = {width: 20, depth: 15}; globalThis.phone = {pose: {x: 0, y: 8, heading: 0}}');
  const at = id => JSON.parse(JSON.stringify(run(`rehearsalPosition(room, phone, '${id}')`)));
  assert.deepEqual([at('in-frame').x, at('in-frame').y, at('in-frame').distance], [0, 2, 6]);
  assert.ok(at('across-floor').x < 0, 'a negative bearing goes to the phone\u2019s left');
  assert.ok(at('right-beside').x > 0, 'a positive bearing goes to the phone\u2019s right');
  assert.ok(at('behind-you').y > 8, 'a rear bearing goes toward the back of the room');
});

test('venue scenarios land on a room landmark whatever the phone is doing', () => {
  const at = (id, phone) => JSON.parse(JSON.stringify(
    run(`rehearsalPosition({width:20,depth:15,stage:{width:8,depth:2.5}}, ${JSON.stringify(phone)}, '${id}')`)));
  const facingStage = at('back-bar', {pose: {x: 0, y: 8, heading: 0}});
  const facingBack = at('back-bar', {pose: {x: 4, y: 3, heading: 180}});
  assert.deepEqual([facingStage.x, facingStage.y], [facingBack.x, facingBack.y]);
  assert.ok(facingStage.y > 12 && facingStage.x < -6, 'the back bar sits in the far corner');
  const barrier = at('barrier', {pose: {x: 0, y: 8, heading: 0}});
  assert.ok(barrier.y < 2 && barrier.x < 0, 'the barrier sits at the rail, house left');
});

test('every venue landmark stays inside the room, and every bearing stops at a wall', () => {
  const rooms = ['{width:20,depth:15,stage:{width:8,depth:2.5}}', '{width:6,depth:5,stage:{width:4,depth:1.5}}'];
  for (const room of rooms) {
    for (const id of run('REHEARSAL_SCENARIOS.map(s => s.id)')) {
      const spot = run(`rehearsalPosition(${room}, {pose:{x:0,y:1,heading:35}}, '${id}')`);
      if (!spot) continue;
      const {width, depth} = run(`(${room})`);
      assert.ok(Math.abs(spot.x) <= width / 2, `${id} stays within the room width`);
      assert.ok(spot.y >= 0 && spot.y <= depth, `${id} stays within the room depth`);
    }
  }
});

test('scenario distance shortens at a room edge without changing direction', () => {
  const result = JSON.parse(JSON.stringify(run("rehearsalPosition({width:20,depth:15},{pose:{x:0,y:2,heading:0}},'in-frame')")));
  assert.equal(result.x, 0);
  assert.equal(result.y, 0.35);
  assert.equal(result.distance, 1.6);
});

test('every scenario carries a group and a briefing line for the operator', () => {
  const scenarios = JSON.parse(run('JSON.stringify(REHEARSAL_SCENARIOS)'));
  assert.ok(scenarios.length >= 6);
  for (const scenario of scenarios) {
    assert.ok(scenario.group && scenario.label && scenario.detail, `${scenario.id} is fully described`);
  }
  assert.ok(new Set(scenarios.map(s => s.group)).size >= 3, 'scenarios are grouped for the picker');
});

test('the console no longer offers rehearsal mode', () => {
  const html = fs.readFileSync('web/console.html', 'utf8');
  const code = fs.readFileSync('web/console.js', 'utf8');
  assert.doesNotMatch(html, /rehearsal/i);
  assert.doesNotMatch(code, /rehearsal-scenarios\.js/);
});
