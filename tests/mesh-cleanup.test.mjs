import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const {cleanMeshes}=await import('data:text/javascript;base64,'+readFileSync('web/mesh-cleanup.js').toString('base64'));
function mesh(section,offset=0,shift=0) {
 return {section,positions:new Float32Array([.01+shift,offset,.01,.04+shift,offset,.01,.01+shift,offset,.04]),indices:new Uint32Array([0,1,2])};
}
test('keeps established geometry and removes coplanar overlap',()=>{
 const r=cleanMeshes([mesh('a'),mesh('b',.005)]);
 assert.equal(r.masks[0].length,3);assert.equal(r.masks[1].length,0);
});
test('preserves new coverage and inconsistent parallel surfaces',()=>{
 const r=cleanMeshes([mesh('a'),mesh('b',.1),mesh('c',0,1)]);
 assert.equal(r.removed,0);
});
test('does not remove adjacent triangles from the same section',()=>{
 assert.equal(cleanMeshes([mesh('a'),mesh('a')]).removed,0);
});
test('handles empty and invalid meshes',()=>{
 assert.equal(cleanMeshes([]).total,0);
 const m=mesh('x');m.positions.fill(NaN);assert.equal(cleanMeshes([m]).removed,1);
});

test('preserves disjoint coplanar details within the same voxel',()=>{
 assert.equal(cleanMeshes([mesh('a'),mesh('b',0,.04)]).removed,0);
});
test('suppresses doubled surfaces six centimetres apart',()=>{
 const r=cleanMeshes([mesh('a'),mesh('b',.06)]);
 assert.equal(r.removed,1);
});
test('best-covered section owns patch while other sections keep unique cells',()=>{
 const join=(section,parts)=>({section,positions:Float32Array.from(parts.flatMap(m=>Array.from(m.positions))),indices:Uint32Array.from(parts.flatMap((m,i)=>[i*3,i*3+1,i*3+2]))});
 const a=join('a',[mesh('a'),mesh('a',0,.15)]);
 const b=join('b',[mesh('b',.03),mesh('b',.03,.04),mesh('b',.03,.08)]);
 const r=cleanMeshes([a,b]);
 assert.equal(r.masks[0].length,3); // unique distant cell stays
 assert.equal(r.masks[1].length,9); // best coverage wins, not first arrival
});
