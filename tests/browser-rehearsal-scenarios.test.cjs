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

test('direction scenarios use the phone heading and room coordinate system', () => {
  run('globalThis.room = {width: 20, depth: 15}; globalThis.phone = {pose: {x: 0, y: 8, heading: 0}}');
  assert.deepEqual(JSON.parse(JSON.stringify(run("rehearsalPosition(room, phone, 'ahead')"))),
    {x: 0, y: 3, distance: 5, scenario: {id: 'ahead', label: 'Directly ahead', offset: 0, distance: 5}});
  assert.deepEqual(JSON.parse(JSON.stringify(run("rehearsalPosition(room, phone, 'left')"))).x, -5);
  assert.deepEqual(JSON.parse(JSON.stringify(run("rehearsalPosition(room, phone, 'right')"))).x, 5);
  assert.deepEqual(JSON.parse(JSON.stringify(run("rehearsalPosition(room, phone, 'behind')"))).y, 13);
});

test('scenario distance shortens at a room edge without changing direction', () => {
  const result = JSON.parse(JSON.stringify(run("rehearsalPosition({width:20,depth:15},{pose:{x:0,y:2,heading:0}},'ahead')")));
  assert.equal(result.x, 0);
  assert.equal(result.y, 0.35);
  assert.equal(result.distance, 1.6);
});

test('scenario selector is present in the person reference tools', () => {
  const html = fs.readFileSync('web/console.html', 'utf8');
  const code = fs.readFileSync('web/console.js', 'utf8');
  assert.match(html, /id="rehearsalScenario"/);
  assert.match(html, /id="runScenario"/);
  assert.match(code, /type: 'target', x: placement\.x, y: placement\.y/);
});
