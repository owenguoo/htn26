import struct

import pytest

from swarm.protocol import pack, unpack


def test_roundtrip():
    assert unpack(pack({'seq': 0}, b'jpeg')) == ({'seq': 0}, b'jpeg')


@pytest.mark.parametrize('data', [b'', b'abc', struct.pack('>I', 9) + b'{}', pack([], b'x')])
def test_invalid_headers(data):
    with pytest.raises(ValueError):
        unpack(data)
