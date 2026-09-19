const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({});
const source = fs.existsSync('web/inference-ui.js') ? fs.readFileSync('web/inference-ui.js','utf8').replaceAll('export ', '') : '';
vm.runInContext(source, context);
const run = (s) => vm.runInContext(s, context);
test('phone rejects old streams, sequences and revisions and expires from original capture', () => {
  assert.equal(run('typeof acceptDetection'), 'function');
  run("globalThis.s = {streamId:'new', revision:null, seq:-1, captures:new Map([[4,100],[5,200]])}");
  assert.equal(run("acceptDetection(s,{streamId:'old',seq:4,searchRevision:'a',boxes:[{}]},1000)"), null);
  assert.equal(run("acceptDetection(s,{streamId:'new',seq:4,searchRevision:'a',boxes:[{}]},1000).until"),1600);
  assert.equal(run("acceptDetection(s,{streamId:'new',seq:4,searchRevision:'a',boxes:[{}]},1001)"),null);
  run("acceptDetection(s,{clear:true,searchRevision:'b'},1002)");
  assert.equal(run("acceptDetection(s,{streamId:'new',seq:5,searchRevision:'a',boxes:[{}]},1003)"),null);
  assert.equal(run("acceptDetection(s,{streamId:'new',seq:5,searchRevision:'b',boxes:[]},1800)"),null);
});
test('exact source identity includes stream and reference revision', () => {
  assert.equal(run('typeof frameKey'),'function');
  assert.notEqual(run("frameKey({phoneId:'p',streamId:'a',seq:1,searchRevision:'r'})"),run("frameKey({phoneId:'p',streamId:'b',seq:1,searchRevision:'r'})"));
});
test('sighting freshness uses server snapshot age plus elapsed monotonic time', () => {
  assert.equal(run('typeof freshSighting'),'function');
  assert.equal(run("freshSighting({t:100,searchRevision:'r'}, {active:true,searchRevision:'r'},1100,200,701)"),false);
  assert.equal(run("freshSighting({t:100,searchRevision:'old'}, {active:true,searchRevision:'r'},1100,200,201)"),false);
});
test('zero detections replace previous overlay and a clear allows the new reference', () => {
  run("globalThis.z = {streamId:'s',revision:null,seq:-1,captures:new Map([[1,0],[2,100]])}");
  assert.equal(run("acceptDetection(z,{streamId:'s',seq:1,searchRevision:'r',boxes:[]},500).boxes.length"),0);
  run("acceptDetection(z,{clear:true,searchRevision:'next'},600)");
  assert.equal(run("acceptDetection(z,{streamId:'s',seq:2,searchRevision:'next',boxes:[]},700).until"),1600);
});
test('phone cover-fit maps portrait, landscape and rotation', () => {
  const phone = fs.readFileSync('web/phone.js','utf8');
  const fn = phone.slice(phone.indexOf('function frameToScreen('),phone.indexOf('\n}', phone.indexOf('function frameToScreen(')) + 2);
  const ctx = vm.createContext({});
  vm.runInContext("let FAKE=false;let video={videoWidth:1280,videoHeight:720};const $=()=>video;"+fn,ctx);
  const point = s => JSON.parse(JSON.stringify(vm.runInContext(s,ctx)));
  assert.deepEqual(point('frameToScreen(.5,.5,390,844)'),[195,422]);
  assert.deepEqual(point('frameToScreen(0,0,1280,720)'),[0,0]);
  assert.deepEqual(point('video={videoWidth:720,videoHeight:1280};frameToScreen(.5,.5,844,390)'),[422,195]);
});
test('score label keeps appearance similarity separate from detection confidence', () => {
  assert.equal(run("scoreLabel({similarity:.73,detectionScore:.91})"),'Similarity 0.73 · confidence 91%');
});
test('console never substitutes a live thumbnail for missing exact source and ignores obsolete image loads', () => {
  const code = fs.readFileSync('web/console.js','utf8');
  const render = code.slice(code.indexOf('function renderAnalysis()'),code.indexOf('\nsetInterval(() => { if (viewing)'));
  const sandbox = vm.createContext({});
  vm.runInContext(source + `
    let analysisKey=null, viewing='p', snapshotAt=0, searchBusy=false;
    const performance={now:()=>100};
    const nodes={'#confirmSighting':{},'#analyzedFrame':{hidden:false,getContext:()=>({drawImage(){},strokeRect(){}})},'#analysisMeta':{textContent:''}};
    const $=s=>nodes[s];
    const sourceFrames=new Map();
    let pending;
    class Image {constructor(){pending=this;}}
    const result={phoneId:'p',streamId:'s',seq:1,searchRevision:'r',t:0,boxes:[],matched:false,width:10,height:10};
    const st={t:0,search:{active:true,searchRevision:'r',sightings:[result]}};
  ` + render,sandbox);
  vm.runInContext('renderAnalysis()',sandbox);
  assert.equal(vm.runInContext("nodes['#analyzedFrame'].hidden",sandbox),true);
  assert.match(vm.runInContext("nodes['#analysisMeta'].textContent",sandbox),/Exact preview unavailable/);
  vm.runInContext("sourceFrames.set(frameKey(result),{url:'exact'});renderAnalysis();st.search.sightings=[];renderAnalysis();pending.onload()",sandbox);
  assert.equal(vm.runInContext("nodes['#analyzedFrame'].hidden",sandbox),true);
});
test('reference numbers remain readable at a 210 by 280 CSS pixel portrait preview', () => {
  const code = fs.readFileSync('web/console.js','utf8');
  const fn = code.slice(code.indexOf('function paintPeople('),code.indexOf("\n$('#referenceFile').addEventListener"));
  const sandbox = vm.createContext({});
  vm.runInContext(`const ctx={beginPath(){},moveTo(){},lineTo(){},stroke(){},strokeRect(){},fillRect(){},fillText(text){this.label=text;}};const canvas={width:960,height:1280,getContext:()=>ctx,getBoundingClientRect:()=>({width:210,height:280})};`+fn,sandbox);
  vm.runInContext('paintPeople(canvas,[{box:[100,100,400,900]}])',sandbox);
  assert.ok(vm.runInContext("parseFloat(ctx.font.split(' ')[1])*210/960 >= 14",sandbox));
  assert.equal(vm.runInContext('ctx.label',sandbox),'1');
});
test('reference controls are visible without an operator session', () => {
  const html=fs.readFileSync('web/console.html','utf8');
  const code=fs.readFileSync('web/console.js','utf8');
  assert.doesNotMatch(html, /id="(?:loginForm|operatorCode|logout)"/);
  assert.match(html, /<fieldset id="searchTools" style=/);
  assert.doesNotMatch(code, /api\/session|authenticated|sessionGeneration/);
});
test('overlapping reference boxes keep every numeric marker visible', () => {
  const code = fs.readFileSync('web/console.js','utf8');
  const fn = code.slice(code.indexOf('function paintPeople('),code.indexOf("\n$('#referenceFile').addEventListener"));
  const sandbox = vm.createContext({});
  vm.runInContext(`const rects=[];const ctx={strokeRect(){},fillRect(x,y,w,h){rects.push({x,y,w,h})},fillText(){},beginPath(){},moveTo(){},lineTo(){},stroke(){}};const canvas={width:960,height:1280,getContext:()=>ctx,getBoundingClientRect:()=>({width:210,height:280})};`+fn,sandbox);
  vm.runInContext('paintPeople(canvas,Array.from({length:5},()=>({box:[100,100,400,900]})))',sandbox);
  const rects = JSON.parse(vm.runInContext('JSON.stringify(rects)',sandbox));
  for (const [i,a] of rects.entries()) {
    assert.ok(a.x >= 0 && a.y >= 0 && a.x+a.w <= 960 && a.y+a.h <= 1280);
    for (const b of rects.slice(i+1)) assert.ok(a.x+a.w <= b.x || b.x+b.w <= a.x || a.y+a.h <= b.y || b.y+b.h <= a.y);
  }
});
test('viewer has one overflow rule enabling vertical scrolling', () => {
  const html = fs.readFileSync('web/console.html','utf8');
  const rules = [...html.matchAll(/\.vbox\s*\{([^}]+)\}/g)].map(match=>match[1]);
  assert.equal(rules.length,1);
  assert.match(rules[0],/overflow-y:\s*auto/);
  assert.doesNotMatch(rules[0],/overflow:\s*hidden/);
});
test('confirmation button captures exact sighting identity and hides on expiry', async () => {
  const code=fs.readFileSync('web/console.js','utf8');
  const render=code.slice(code.indexOf('function renderAnalysis()'),code.indexOf('\nsetInterval(() => { if (viewing)'));
  const sandbox=vm.createContext({});
  vm.runInContext(source+`
    let analysisKey=null,viewing='p',snapshotAt=0,searchBusy=false;
    let clock=100, submitted;
    const performance={now:()=>clock};
    const nodes={'#confirmSighting':{},'#analyzedFrame':{hidden:true},'#analysisMeta':{},'#searchMessage':{}};
    const $=s=>nodes[s],sourceFrames=new Map();
    const searchAction=fn=>fn();
    const searchApi=async (path,options)=>{submitted=JSON.parse(options.body);return {sightings:[]};};
    const result={phoneId:'p',streamId:'s',seq:1,searchRevision:'r',t:0,boxes:[],matched:true};
    const st={t:0,search:{active:true,searchRevision:'r',sightings:[result]}};
  `+render,sandbox);
  vm.runInContext('renderAnalysis(); const click=nodes["#confirmSighting"].onclick; result.seq=2;',sandbox);
  await vm.runInContext('click()',sandbox);
  assert.equal(vm.runInContext('submitted.seq',sandbox),1);
  assert.equal(vm.runInContext('submitted.streamId',sandbox),'s');
  vm.runInContext('st.search={active:true,searchRevision:"r",sightings:[result]};clock=1600;renderAnalysis()',sandbox);
  assert.equal(vm.runInContext('nodes["#confirmSighting"].hidden',sandbox),true);
  assert.equal(vm.runInContext('nodes["#confirmSighting"].onclick',sandbox),null);
});

test('phone HUD mirrors accepted detections using the capture clock and clears on expiry', () => {
  const phone = fs.readFileSync('web/phone.js', 'utf8');
  const mirror = phone.slice(phone.indexOf('const hud = '), phone.indexOf('\nfunction drawAR('));
  const sandbox = vm.createContext({});
  vm.runInContext(source + `
    let now=100, sent, tick;
    const performance={now:()=>now};
    const Date={now:()=>1700000000000};
    const $=()=>({classList:{contains:()=>false},textContent:''});
    const setInterval=fn=>tick=fn;
    const sendJson=msg=>sent=msg;
    const state={dets:acceptDetection({streamId:'s',revision:null,seq:-1,captures:new Map([[1,0]])},
      {streamId:'s',seq:1,searchRevision:'r',boxes:[{x:.1,y:.2,w:.3,h:.4}]},now)};
  ` + mirror + 'hud.on=true;tick();', sandbox);
  assert.equal(vm.runInContext('sent.dets?.length', sandbox), 1);
  vm.runInContext('now=1501;tick()', sandbox);
  assert.equal(vm.runInContext('sent.dets', sandbox), null);
});

test('rehearsal detections retain stream and revision guards and clear with real search', () => {
  const phone=fs.readFileSync('web/phone.js','utf8');
  const command=phone.slice(phone.indexOf('function onCommand('),phone.indexOf('// ---------------------------------------------------------------- compass tape'));
  const sandbox=vm.createContext({});
  vm.runInContext(source + `
    const performance={now:()=>100};
    const state={dets:null,detection:{streamId:'s',revision:null,seq:-1,captures:new Map([[1,0],[2,50]])}};
    const message={cmd:'rehearsal_detections',streamId:'s',seq:1,searchRevision:'mock',boxes:[{score:.9}]};
  ` + command, sandbox);
  vm.runInContext('onCommand(message)',sandbox);
  assert.equal(vm.runInContext('state.dets?.rehearsal',sandbox),true);
  vm.runInContext("onCommand({cmd:'detections',clear:true,searchRevision:'real'})",sandbox);
  assert.equal(vm.runInContext('state.dets',sandbox),null);
  vm.runInContext('onCommand({...message,seq:2})',sandbox);
  assert.equal(vm.runInContext('state.dets',sandbox),null);
});
