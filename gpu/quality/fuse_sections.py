"""Offline surface consolidation; never modifies source sections or live manifests."""
import argparse,json,struct,time
from pathlib import Path
import sys
import numpy as np
import open3d as o3d
import DracoPy
from scipy.spatial import cKDTree
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mesh_glb import export_mesh


def read_mesh(path, tf):
    raw=path.read_bytes(); length=struct.unpack_from('<I',raw,12)[0]
    doc=json.loads(raw[20:20+length]);start=28+length
    prim=doc['meshes'][0]['primitives'][0]
    view=doc['bufferViews'][prim['extensions']['KHR_draco_mesh_compression']['bufferView']]
    mesh=DracoPy.decode(raw[start+view.get('byteOffset',0):start+view.get('byteOffset',0)+view['byteLength']])
    pts=np.asarray(mesh.points,dtype=float); angle=np.deg2rad(tf['rotateYDeg']);c,s=np.cos(angle),np.sin(angle)
    rot=np.array([[c,0,s],[0,1,0],[-s,0,c]])
    pts=tf['scale']*(pts@rot.T)+tf['offset']
    m=o3d.geometry.TriangleMesh(o3d.utility.Vector3dVector(pts),o3d.utility.Vector3iVector(mesh.faces))
    m.vertex_colors=o3d.utility.Vector3dVector(np.asarray(mesh.colors)[:,:3]/255.)
    m.compute_vertex_normals()
    return m


def consolidate(source, output):
    start=time.monotonic();manifest=json.loads((source/'last.json').read_text());reports=[]
    combined=o3d.geometry.PointCloud()
    for section in manifest['sections']:
        mesh=read_mesh(source/Path(section['url']).name,section['autoTransform'])
        cloud=o3d.geometry.PointCloud();cloud.points=mesh.vertices;cloud.colors=mesh.vertex_colors;cloud.normals=mesh.vertex_normals
        cloud=cloud.voxel_down_sample(.025)
        result={'version':section['version'],'points':len(cloud.points),'refined':False}
        correction=np.eye(4)
        if len(combined.points):
            reg=o3d.pipelines.registration.registration_icp(cloud,combined,.12,np.eye(4),
                o3d.pipelines.registration.TransformationEstimationPointToPlane(),
                o3d.pipelines.registration.ICPConvergenceCriteria(max_iteration=25))
            positions=np.asarray(cloud.points)
            moved=positions@reg.transformation[:3,:3].T+reg.transformation[:3,3]
            shift=float(np.percentile(np.linalg.norm(moved-positions,axis=1),95));angle=float(np.arccos(np.clip((np.trace(reg.transformation[:3,:3])-1)/2,-1,1)))
            result.update(fitness=reg.fitness,rmse=reg.inlier_rmse,displacement95=shift,rotationDegrees=float(np.rad2deg(angle)))
            if reg.fitness>.35 and shift<.15 and angle<np.deg2rad(5):
                cloud.transform(reg.transformation);correction=reg.transformation;result['refined']=True
        # Orient reconstructed surface normals toward the cameras that observed it.
        cams=[manifest['placed'][k] for k in section['frames'] if k in manifest['placed']]
        if cams:
            pts=np.asarray(cloud.points); normals=np.asarray(cloud.normals).copy()
            cameras=np.asarray(cams)@correction[:3,:3].T+correction[:3,3];_,nearest=cKDTree(cameras).query(pts)
            normals[np.einsum('ij,ij->i',normals,cameras[nearest]-pts)<0]*=-1
            cloud.normals=o3d.utility.Vector3dVector(normals)
        combined+=cloud;combined=combined.voxel_down_sample(.025)
        reports.append(result);print(json.dumps(result),flush=True)
    combined,indices=combined.remove_statistical_outlier(nb_neighbors=20,std_ratio=2.5)
    combined.normalize_normals()
    mesh,density=o3d.geometry.TriangleMesh.create_from_point_cloud_poisson(combined,depth=8,n_threads=8)
    points=np.asarray(mesh.vertices)
    distance,nearest=cKDTree(np.asarray(combined.points)).query(points)
    mesh.vertex_colors=o3d.utility.Vector3dVector(np.asarray(combined.colors)[nearest])
    # Poisson closes unseen space; explicitly remove unsupported extrapolation.
    mesh.remove_vertices_by_mask((distance>.06)|(np.asarray(density)<np.quantile(density,.02)))
    labels,counts,areas=mesh.cluster_connected_triangles()
    mesh.remove_triangles_by_mask(np.asarray(areas)[np.asarray(labels)]<.025)
    mesh.remove_unreferenced_vertices()
    if len(mesh.triangles)>300000:mesh=mesh.simplify_quadric_decimation(300000)
    mesh=mesh.filter_smooth_taubin(number_of_iterations=2)
    output.mkdir(parents=True,exist_ok=True)
    (output/'fused.glb').write_bytes(export_mesh(np.asarray(mesh.vertices),np.asarray(mesh.triangles),np.clip(np.asarray(mesh.vertex_colors)*255,0,255).astype(np.uint8)))
    report={'seconds':time.monotonic()-start,'points':len(combined.points),'faces':len(mesh.triangles),'sections':reports}
    (output/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--output',required=True);a=p.parse_args();consolidate(Path(a.input),Path(a.output))
