import pytest
from pydantic import ValidationError

from swarm.detection import DetectionResult, FrameSnapshot, SearchState, normalize_box, captured_at_seconds


def setup_state():
    state = SearchState()
    state.set_reference('target')
    state.connect('phone', 'stream')
    frame = FrameSnapshot('phone', 'stream', 0, 1000, 480, 640, {'x': 1, 'heading': 90})
    state.record_frame(frame)
    result = dict(phoneId='phone', streamId='stream', seq=0, t=1000,
                  searchRevision=state.revision, targetVersion='target', width=480, height=640,
                  boxes=[dict(x=.1, y=.2, w=.3, h=.6, label='person', detectionScore=.91, similarity=.82)],
                  queueMs=10, inferenceMs=70, matchingMs=15)
    return state, result


def test_normalization_and_timestamp():
    assert normalize_box((48, 128, 192, 512), 480, 640) == dict(x=.1, y=.2, w=.3, h=.6)
    assert captured_at_seconds(1750000000123) == 1750000000.123


def test_current_and_duplicate():
    state, result = setup_state()
    assert state.accept_result(result, now_ms=1200)
    assert state.latest['phone'].matched
    assert state.latest['phone'].pose['heading'] == 90
    assert not state.accept_result(result, now_ms=1210)


@pytest.mark.parametrize(('field', 'value'), [('searchRevision', 'old'), ('streamId', 'old'),
    ('phoneId', 'unknown'), ('targetVersion', 'old'), ('seq', 1), ('t', 999), ('width', 481)])
def test_reject_mismatch(field, value):
    state, result = setup_state()
    result[field] = value
    assert not state.accept_result(result, now_ms=1200)


def test_expiry_disconnect_reconnect():
    state, result = setup_state()
    assert not state.accept_result(result, now_ms=2501)
    state, result = setup_state()
    state.disconnect('phone', 'stream')
    assert not state.accept_result(result, now_ms=1200)
    state.connect('phone', 'new')
    state.record_frame(FrameSnapshot('phone', 'new', 0, 1000, 480, 640, None))
    assert not state.accept_result(result, now_ms=1200)
    result['streamId'] = 'new'
    assert state.accept_result(result, now_ms=1200)
    state.expire(2501)
    assert not state.latest


@pytest.mark.parametrize(('field', 'value'), [('similarity', float('nan')), ('similarity', float('inf')),
    ('detectionScore', -1), ('x', -.1), ('w', 0), ('h', .9), ('label', 'dog')])
def test_invalid_boxes(field, value):
    state, result = setup_state()
    result['boxes'][0][field] = value
    with pytest.raises(ValidationError):
        DetectionResult.model_validate(result)
    assert not state.accept_result(result, now_ms=1200)


def test_zero_candidates_and_revision_clear():
    state, result = setup_state()
    assert state.accept_result(result, now_ms=1200)
    state.record_frame(FrameSnapshot('phone', 'stream', 1, 1100, 480, 640, None))
    result.update(seq=1, t=1100, boxes=[])
    assert state.accept_result(result, now_ms=1200)
    assert not state.latest['phone'].matched
    revision = state.revision
    state.set_threshold(.9)
    assert state.revision != revision
    assert not state.latest


def test_frame_metadata_bounded_and_new_frame_does_not_invalidate_result():
    state, result = setup_state()
    state.record_frame(FrameSnapshot('phone', 'stream', 1, 1100, 480, 640, None))
    assert state.accept_result(result, now_ms=1200)
    for seq in range(2, 200):
        state.record_frame(FrameSnapshot('phone', 'stream', seq, 1000 + seq, 480, 640, None))
    assert len(state.frames['phone']) <= 32


@pytest.mark.parametrize('bounds', [(0, 0, 0, 20), (0, 0, 481, 20), (float('nan'), 0, 20, 20)])
def test_reject_invalid_pixel_bounds(bounds):
    with pytest.raises(ValueError):
        normalize_box(bounds, 480, 640)


@pytest.mark.parametrize(('field', 'value'), [('seq', True), ('seq', -1), ('t', float('nan')),
    ('queueMs', float('inf')), ('matchingMs', -1), ('height', 0)])
def test_invalid_result_fields(field, value):
    state, result = setup_state()
    result[field] = value
    assert not state.accept_result(result, now_ms=1200)


def test_expired_latest_clears_even_when_new_result_rejected():
    state, result = setup_state()
    assert state.accept_result(result, now_ms=1200)
    assert not state.accept_result(result, now_ms=2501)
    assert not state.latest


def test_reset_and_disconnect_old_stream_preserve_current_connection():
    state, result = setup_state()
    state.connect('phone', 'new')
    state.disconnect('phone', 'stream')
    assert state.streams['phone'] == 'new'
    state.reset()
    assert state.target_version == 'target'
    assert state.revision != result['searchRevision']


def test_worker_identifiers_ignore_arbitrary_phone_id():
    frame = FrameSnapshot('!' * 500, 'b7bac91a-b903-424a-9d11-4d7ab5e03ed2', 0, 1000, 480, 640, None)
    assert frame.worker_phone_id == frame.stream_id
    assert frame.worker_frame_id == frame.stream_id + ':0'


def test_default_threshold_accepts_similarity_between_point_seven_and_point_seven_five():
    state, result = setup_state()
    result['boxes'][0]['similarity'] = .72
    assert state.accept_result(result, now_ms=1200)
    assert state.latest['phone'].matched
    assert state.threshold == .70
