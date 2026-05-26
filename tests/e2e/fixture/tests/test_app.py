import pytest

import app
import store


@pytest.fixture(autouse=True)
def _reset():
    store.reset()
    yield
    store.reset()


def test_min_age_accepted():
    app.register("alice", 18)
    assert app.lookup("alice") == 18


def test_max_age_accepted():
    app.register("bob", 99)
    assert app.lookup("bob") == 99


def test_below_min_rejected():
    with pytest.raises(store.StoreError):
        app.register("kid", 17)


def test_above_max_rejected():
    with pytest.raises(store.StoreError):
        app.register("elder", 100)


def test_empty_name_rejected():
    with pytest.raises(store.StoreError):
        app.register("   ", 30)
