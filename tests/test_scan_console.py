import json

from fastapi.testclient import TestClient

from swarm.hub import app


def test_console_controls_reach_scanner(monkeypatch, tmp_path):
    monkeypatch.delenv('MAP_WORKER_URL', raising=False)
    monkeypatch.delenv('MAP_WORKER_SSH', raising=False)
    monkeypatch.setattr('swarm.hub.WEB', tmp_path)
    with TestClient(app) as client:
        assert client.get('/api/state').json()['scan']['configured'] is False
        with client.websocket_connect('/ws/dashboard?role=console',
                                      headers={'origin': 'http://testserver'}) as ws:
            ws.receive_json()
            ws.send_json({'type': 'scan', 'enabled': True})
            for _ in range(20):
                message = ws.receive()
                if message.get('text'):
                    state = json.loads(message['text'])
                    if state.get('type') == 'state' and state['scan']['enabled']:
                        break
            else:
                raise AssertionError('Scan control did not reach mapper')
