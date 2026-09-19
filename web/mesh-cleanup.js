// Display-only patch ownership; source meshes remain unchanged.
// 24 cm patches choose one section by projected coverage, then surface area.
// 3 cm coverage cells let non-winning sections fill holes and extend the map.
export function cleanMeshes(meshes, patchSize = .24, tolerance = .08) {
  const patches = new Map(), groups = [], assignments = [];
  let total=0,removed=0;
  const fine=8;
  for (const mesh of meshes) {
    const p=mesh.positions, indices=mesh.indices;
    const ids=new Int32Array(indices.length/3).fill(-1), slots=new Uint8Array(ids.length);
    for(let i=0;i<indices.length;i+=3) {
      total++;
      const a=indices[i]*3,b=indices[i+1]*3,c=indices[i+2]*3;
      const center=[(p[a]+p[b]+p[c])/3,(p[a+1]+p[b+1]+p[c+1])/3,(p[a+2]+p[b+2]+p[c+2])/3];
      const u=[p[b]-p[a],p[b+1]-p[a+1],p[b+2]-p[a+2]],v=[p[c]-p[a],p[c+1]-p[a+1],p[c+2]-p[a+2]];
      const normal=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]];
      const len=Math.hypot(...normal);
      if (!Number.isFinite(center[0]+center[1]+center[2]+len) || len<1e-12) continue;
      let axis=0;
      if(Math.abs(normal[1])>Math.abs(normal[axis]))axis=1;
      if(Math.abs(normal[2])>Math.abs(normal[axis]))axis=2;
      const sign=normal[axis]<0?-1:1;
      for(let j=0;j<3;j++)normal[j]*=sign/len;
      const ta=(axis+1)%3,tb=(axis+2)%3;
      const x=Math.floor(center[ta]/patchSize),y=Math.floor(center[tb]/patchSize);
      const key=`${axis},${x},${y}`;
      let candidates=patches.get(key);
      if(!candidates){candidates=[];patches.set(key,candidates);}
      let group=candidates.find(g=>g.normal.reduce((sum,n,j)=>sum+n*normal[j],0)>.9 &&
        Math.abs(g.normal.reduce((sum,n,j)=>sum+n*(center[j]-g.center[j]),0))<=tolerance);
      if(!group){
        group={id:groups.length,normal,center,sections:new Map()};
        candidates.push(group);groups.push(group);
      }
      let section=group.sections.get(mesh.section);
      if(!section){section={id:mesh.section,coverage:new Uint8Array(64),count:0,area:0};group.sections.set(mesh.section,section);}
      const sx=Math.min(7,Math.max(0,Math.floor((center[ta]/patchSize-x)*fine)));
      const sy=Math.min(7,Math.max(0,Math.floor((center[tb]/patchSize-y)*fine)));
      const slot=sy*fine+sx;
      if(!section.coverage[slot]){section.coverage[slot]=1;section.count++;}
      section.area+=Math.min(len/2,patchSize*patchSize);
      ids[i/3]=group.id;slots[i/3]=slot;
    }
    assignments.push({ids,slots});
  }
  for(const group of groups){
    let owner=null;
    for(const section of group.sections.values()) {
      if(!owner || section.count>owner.count || (section.count===owner.count && section.area>owner.area*1.2))owner=section;
    }
    group.owner=owner;
  }
  const masks=meshes.map((mesh,mi)=>{
    const {ids,slots}=assignments[mi],out=new Uint32Array(mesh.indices.length);let count=0;
    for(let i=0;i<ids.length;i++){
      const owner=ids[i]<0?null:groups[ids[i]].owner;
      if(!owner || (owner.id!==mesh.section && owner.coverage[slots[i]])){removed++;continue;}
      out[count++]=mesh.indices[i*3];out[count++]=mesh.indices[i*3+1];out[count++]=mesh.indices[i*3+2];
    }
    return out.slice(0,count);
  });
  return {masks,total,removed,cells:groups.length};
}
