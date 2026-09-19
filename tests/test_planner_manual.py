import asyncio

from swarm.hub import Hub, Phone, ROOM
from swarm.mission import MissionControl
from swarm.protocol import now_ms


def test_operator_sector_assignment_produces_guidance():
    hub = Hub()
    hub.phones['p'] = Phone('p', 1, seat={'x': 0, 'y': 5}, heading=0)
    mission = MissionControl(hub, ROOM)
    result = asyncio.run(mission.execute('send_phones_to_sector', {'phones': [1], 'sector': 'D2'}))
    assert 'sent #1' in result
    hub.planner.enabled = True
    commands = hub.planner.tick({'p': (0, 5, 0, None)}, now_ms())
    assert commands[0][0] == 'p'
    assert commands[0][1]['sector'] == 'D2'
    assert isinstance(commands[0][1]['delta'], float)
