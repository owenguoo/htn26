import {cleanMeshes} from './mesh-cleanup.js';
self.onmessage = ({data}) => {
  try {
    const start=performance.now();
    const result=cleanMeshes(data.meshes);
    self.postMessage({...result,ms:performance.now()-start},result.masks.map(m=>m.buffer));
  } catch (error) { self.postMessage({error:String(error)}); }
};
