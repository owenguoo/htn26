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
test('phone cover-fit maps portrait, landscape, rotation and SLAM coordinates', () => {
  const phone = fs.readFileSync('web/phone.js','utf8');
  const fn = phone.slice(phone.indexOf('function frameToScreen('),phone.indexOf('\nfunction drawAR('));
  const ctx = vm.createContext({});
  vm.runInContext("let SLAM=false,FAKE=false;let video={videoWidth:1280,videoHeight:720};const $=()=>video;"+fn,ctx);
  const point = s => JSON.parse(JSON.stringify(vm.runInContext(s,ctx)));
  assert.deepEqual(point('frameToScreen(.5,.5,390,844)'),[195,422]);
  assert.deepEqual(point('frameToScreen(0,0,1280,720)'),[0,0]);
  assert.deepEqual(point('video={videoWidth:720,videoHeight:1280};frameToScreen(.5,.5,844,390)'),[422,195]);
  assert.deepEqual(point('SLAM=true;frameToScreen(.25,.75,400,800)'),[100,600]);
});
test('score label keeps appearance similarity separate from detection confidence', () => {
  assert.equal(run("scoreLabel({similarity:.73,detectionScore:.91})"),'Similarity 0.73 · confidence 91%');
});
test('console never substitutes a live thumbnail for missing exact source and ignores obsolete image loads', () => {
  const code = fs.readFileSync('web/console.js','utf8');
  const render = code.slice(code.indexOf('function renderAnalysis()'),code.indexOf('\nsetInterval(() => { if (viewing)'));
  const sandbox = vm.createContext({});
  vm.runInContext(source + `
    let analysisKey=null, viewing='p', snapshotAt=0;
    const performance={now:()=>100};
    const nodes={'#analyzedFrame':{hidden:false,getContext:()=>({drawImage(){},strokeRect(){}})},'#analysisMeta':{textContent:''}};
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
  vm.runInContext(`const ctx={strokeRect(){},fillRect(){},fillText(text){this.label=text;}};const canvas={width:960,height:1280,getContext:()=>ctx,getBoundingClientRect:()=>({width:210,height:280})};`+fn,sandbox);
  vm.runInContext('paintPeople(canvas,[{box:[100,100,400,900]}])',sandbox);
  assert.ok(vm.runInContext("parseFloat(ctx.font.split(' ')[1])*210/960 >= 14",sandbox));
  assert.equal(vm.runInContext('ctx.label',sandbox),'1');
});
test('a deferred initial session response cannot overwrite newer login or logout', async () => {
  const code = fs.readFileSync('web/console.js','utf8');
  assert.ok(code.includes('async function loadSession()'));
  const fn = code.slice(code.indexOf('async function loadSession()'),code.indexOf('\nloadSession();'));
  const handlers = code.slice(code.indexOf("$('#loginForm').addEventListener"), code.indexOf('function clearReferencePreview()'));
  for (const action of ['login','logout']) {
    const sandbox = vm.createContext({});
    vm.runInContext(`let authenticated=${action === 'logout'},sessionGeneration=0;let resolve,pendingAction;const listeners={};const searchApi=(path,options)=>options ? Promise.resolve({}) : new Promise(r=>resolve=r);const renderSearch=()=>{};const $=id=>({value:'test',addEventListener:(event,fn)=>listeners[id]=fn});const searchAction=fn=>pendingAction=fn();const ws=null;const clearReferencePreview=()=>{};`+fn+handlers,sandbox);
    const pending = vm.runInContext('loadSession()',sandbox);
    vm.runInContext(`listeners['${action === 'login' ? '#loginForm' : '#logout'}']({preventDefault(){}})`,sandbox);
    await vm.runInContext('pendingAction',sandbox);
    vm.runInContext(`resolve({authenticated:${action === 'logout'}})`,sandbox);
    await pending;
    assert.equal(vm.runInContext('authenticated',sandbox),action === 'login');
  }
});
