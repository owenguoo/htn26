"""Keep local service credentials out of the test application's configuration."""
import os

import pytest

from swarm import control


_environment = pytest.MonkeyPatch()


def pytest_configure():
    # Hub initialization reads settings during collection, before fixtures run.
    _environment.setattr(control, 'load_env', lambda *args, **kwargs: None)
    for name in tuple(os.environ):
        if name.startswith(('SWARM_', 'OPENAI_')) and not name.startswith('SWARM_REAL_'):
            _environment.delenv(name)


def pytest_unconfigure():
    _environment.undo()
