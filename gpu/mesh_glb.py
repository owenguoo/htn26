"""A compact, unlit glTF mesh with standard KHR_draco_mesh_compression.

14-bit position quantization is much finer than the reconstruction voxel size.
Colors are linear RGB bytes, encoded losslessly. Attribute IDs come from the
encoder, not assumptions about Draco's internal ordering.
"""
import json
import struct

import DracoPy
import numpy as np


def export_mesh(vertices, faces, colors):
    compressed = DracoPy.encode(np.asarray(vertices, dtype=np.float32),
                                np.asarray(faces, dtype=np.uint32),
                                colors=np.asarray(colors, dtype=np.uint8),
                                quantization_bits=14, compression_level=5)
    decoded = DracoPy.decode(compressed)
    attrs = {a['attribute_type']: a['unique_id'] for a in decoded.attributes}
    document = {
        'asset': {'version': '2.0', 'generator': 'Swarm Sight surface fusion'},
        'extensionsUsed': ['KHR_draco_mesh_compression', 'KHR_materials_unlit'],
        'extensionsRequired': ['KHR_draco_mesh_compression'],
        'scene': 0, 'scenes': [{'nodes': [0]}], 'nodes': [{'mesh': 0}],
        'meshes': [{'primitives': [{'attributes': {'POSITION': 0, 'COLOR_0': 1}, 'indices': 2, 'material': 0,
                    'mode': 4, 'extensions': {'KHR_draco_mesh_compression': {'bufferView': 0,
                        'attributes': {'POSITION': attrs[DracoPy.AttributeType.POSITION],
                                       'COLOR_0': attrs[DracoPy.AttributeType.COLOR]}}}}]}],
        'materials': [{'doubleSided': True, 'extensions': {'KHR_materials_unlit': {}},
                       'pbrMetallicRoughness': {'baseColorFactor': [1, 1, 1, 1], 'metallicFactor': 0, 'roughnessFactor': 1}}],
        'accessors': [
            {'componentType': 5126, 'count': len(decoded.points), 'type': 'VEC3',
             'min': decoded.points.min(0).tolist(), 'max': decoded.points.max(0).tolist()},
            {'componentType': 5121, 'count': len(decoded.colors), 'type': 'VEC3', 'normalized': True},
            {'componentType': 5125, 'count': int(decoded.faces.size), 'type': 'SCALAR'}],
        'buffers': [{'byteLength': len(compressed)}],
        'bufferViews': [{'buffer': 0, 'byteOffset': 0, 'byteLength': len(compressed)}],
    }
    head = json.dumps(document, separators=(',', ':')).encode()
    head += b' ' * (-len(head) % 4)
    binary = compressed + b'\0' * (-len(compressed) % 4)
    return (struct.pack('<4sII', b'glTF', 2, 28 + len(head) + len(binary))
            + struct.pack('<I4s', len(head), b'JSON') + head
            + struct.pack('<I4s', len(binary), b'BIN\0') + binary)
