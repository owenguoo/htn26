// Conservative display-only overlap ownership. Original GLBs stay untouched.
// No surface is invented: only near-coplanar triangles from later sections are hidden.
export function cleanMeshes(meshes, cellSize = 0.04, tolerance = 0.025) {
  const cells = new Map();
  let total = 0, removed = 0;
  const masks = [];
  function inside(px,py,pz,r) {
    const wx=px-r.ax, wy=py-r.ay, wz=pz-r.az;
    const d20=wx*r.ux+wy*r.uy+wz*r.uz, d21=wx*r.vx+wy*r.vy+wz*r.vz;
    const u=(r.d11*d20-r.d01*d21)/r.den, v=(r.d00*d21-r.d01*d20)/r.den;
    if (u >= -1e-4 && v >= -1e-4 && u+v <= 1.0001) return true;
    // Independent triangulations rarely share edges exactly. Allow only a
    // 1 cm boundary mismatch, not ownership of an entire spatial cell.
    const edgeDistance = (ax,ay,az,bx,by,bz) => {
      const ex=bx-ax, ey=by-ay, ez=bz-az;
      const t=Math.max(0,Math.min(1,((px-ax)*ex+(py-ay)*ey+(pz-az)*ez)/(ex*ex+ey*ey+ez*ez)));
      return Math.hypot(px-ax-t*ex,py-ay-t*ey,pz-az-t*ez);
    };
    const bx=r.ax+r.ux, by=r.ay+r.uy, bz=r.az+r.uz;
    const cx=r.ax+r.vx, cy=r.ay+r.vy, cz=r.az+r.vz;
    return Math.min(edgeDistance(r.ax,r.ay,r.az,bx,by,bz),
      edgeDistance(bx,by,bz,cx,cy,cz),edgeDistance(cx,cy,cz,r.ax,r.ay,r.az)) <= .01;
  }
  for (const mesh of meshes) {
    const p = mesh.positions, indices = mesh.indices;
    const kept = new Uint32Array(indices.length);
    let n = 0;
    for (let i = 0; i < indices.length; i += 3) {
      total++;
      const a = indices[i]*3, b = indices[i+1]*3, c = indices[i+2]*3;
      const x = (p[a]+p[b]+p[c])/3, y = (p[a+1]+p[b+1]+p[c+1])/3, z = (p[a+2]+p[b+2]+p[c+2])/3;
      const ux=p[b]-p[a], uy=p[b+1]-p[a+1], uz=p[b+2]-p[a+2];
      const vx=p[c]-p[a], vy=p[c+1]-p[a+1], vz=p[c+2]-p[a+2];
      let nx=uy*vz-uz*vy, ny=uz*vx-ux*vz, nz=ux*vy-uy*vx;
      const len=Math.hypot(nx,ny,nz);
      if (!Number.isFinite(x+y+z+len) || len < 1e-12) { removed++; continue; }
      nx/=len; ny/=len; nz/=len;
      const key=`${Math.floor(x/cellSize)},${Math.floor(y/cellSize)},${Math.floor(z/cellSize)}`;
      const records = cells.get(key) || [];
      const owner = records.find(r => Math.abs(nx*r.nx+ny*r.ny+nz*r.nz) > .97 &&
        [a,b,c].every(v => Math.abs((p[v]-r.x)*r.nx+(p[v+1]-r.y)*r.ny+(p[v+2]-r.z)*r.nz) <= tolerance && inside(p[v],p[v+1],p[v+2],r)));
      if (owner && owner.section !== mesh.section) { removed++; continue; }
      kept[n++]=indices[i]; kept[n++]=indices[i+1]; kept[n++]=indices[i+2];
      // Preserve multiple orientations (e.g. a wall/floor junction), with bounded storage.
      if (!owner && records.length < 8) {
        const d00=ux*ux+uy*uy+uz*uz, d01=ux*vx+uy*vy+uz*vz, d11=vx*vx+vy*vy+vz*vz;
        records.push({x,y,z,nx,ny,nz,ax:p[a],ay:p[a+1],az:p[a+2],ux,uy,uz,vx,vy,vz,
          d00,d01,d11,den:d00*d11-d01*d01,section:mesh.section}); cells.set(key,records);
      }
    }
    masks.push(kept.slice(0,n));
  }
  return {masks,total,removed,cells:cells.size};
}
