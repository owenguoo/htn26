"""Whole-room updates preserve input coverage and never freeze early inferred poses."""
import asyncio
import json
import struct
from unittest.mock import patch

from swarm.hub import Hub, ROOM
from swarm.mapper import Mapper


def test_every_view_is_reconstructed_and_early_geometry_can_change(tmp_path):
    hub=Hub();hub.phase='search'
    mapper=Mapper(hub,ROOM,tmp_path);mapper.mode='global';mapper.url='http://test'
    mapper.keyframes=[{'id':f'k{i}','pid':'phone','jpeg':b'jpeg','t':i,'quality':100} for i in range(88)]
    mapper.pending={k['id'] for k in mapper.keyframes}
    requests=[]
    def response(url,body):
        n,=struct.unpack('>I',body[:4]);header=json.loads(body[4:4+n]);requests.append(header)
        assert len(header['frames'])==88 and header['mode']=='global'
        assert header['voxelResolution']==64
        # Deliberately revise all camera positions: a provisional reconstruction
        # must not veto a later coherent one by comparing old inferred cameras.
        shift=len(requests)*10
        cameras=[{'id':f['id'],'position':[i*.1+shift,1,i*.05],'forward':[0,0,-1]} for i,f in enumerate(header['frames'])]
        meta=json.dumps({'mode':'global','frames':88,'cameras':cameras,'points':1000,'faces':1000,'medianDepth':1,'representation':'surface'}).encode()
        return struct.pack('>I',len(meta))+meta+b'glTF-test'
    with patch('swarm.mapper._post',side_effect=response), patch('swarm.mapper.register_joint',side_effect=AssertionError('must not gate whole-room geometry')):
        asyncio.run(mapper.rebuild())
        assert mapper.last['frames']==88 and not mapper.pending
        mapper.pending={'k87'}
        asyncio.run(mapper.rebuild())
    assert mapper.version==2 and len(mapper.sections)==1 and mapper.error is None
    assert len(mapper.previous_batch)==88
    previous=mapper.last
    mapper.pending={'k87'}
    with patch('swarm.mapper._post',side_effect=RuntimeError('GPU unavailable')): asyncio.run(mapper.rebuild())
    assert mapper.last is previous and mapper.pending=={'k87'}


def test_old_worker_cannot_silently_truncate_global_map(tmp_path):
    hub=Hub();hub.phase='search'
    mapper=Mapper(hub,ROOM,tmp_path);mapper.mode='global';mapper.url='http://test'
    mapper.keyframes=[{'id':f'k{i}','pid':'phone','jpeg':b'jpeg'} for i in range(80)]
    mapper.pending={'k79'}
    meta=json.dumps({'mode':'global','frames':48}).encode()
    with patch('swarm.mapper._post',return_value=struct.pack('>I',len(meta))+meta+b'glTF'):
        asyncio.run(mapper.rebuild())
    assert mapper.last is None and mapper.pending=={'k79'}
    assert 'every selected view' in mapper.error


def test_pending_views_survive_restart_before_first_success(tmp_path):
    from swarm.hub import Phone
    from swarm.protocol import pack
    from tests.test_mapping_capture import jpeg,texture,view
    hub=Hub();hub.phase='search';mapper=Mapper(hub,ROOM,tmp_path);mapper.mode='global'
    phone=Phone(id='phone',index=0);phone.connected=True;hub.phones[phone.id]=phone
    for i in range(4):
        hub.on_frame(phone,pack({'type':'frame','scanKeyframe':True},view(texture(),i*40)))
        mapper.sample_times.clear()
        asyncio.run(mapper.sample())
    assert len(mapper.pending)==4 and mapper.last is None
    restored=Mapper(hub,ROOM,tmp_path)
    assert {k['id'] for k in restored.keyframes}==mapper.pending
    assert restored.pending==mapper.pending
    assert all(k['jpeg'] for k in restored.keyframes)
