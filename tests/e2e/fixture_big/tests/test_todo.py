import pytest

from store import Store
from commands import HANDLERS
from cli import run_line
from errors import NotFoundError, ParseError, ValidationError
from filters import by_status, by_tag, search
from formatter import format_count


@pytest.fixture
def store():
    return Store()


def test_add_returns_id(store):
    assert store.add("buy milk") == 1
    assert store.add("write report") == 2


def test_get_returns_todo(store):
    store.add("buy milk")
    todo = store.get(1)
    assert todo.text == "buy milk"
    assert todo.completed is False


def test_add_empty_rejected(store):
    with pytest.raises(ValidationError):
        store.add("")


def test_mark_done_sets_completed(store):
    store.add("buy milk")
    store.mark_done(1)
    assert store.get(1).completed is True


def test_get_unknown_raises(store):
    with pytest.raises(NotFoundError):
        store.get(99)


def test_remove_renumbers(store):
    store.add("a")
    store.add("b")
    store.add("c")
    store.remove(2)
    assert store.get(1).text == "a"
    assert store.get(2).text == "c"


def test_cli_add_done_show(store):
    assert run_line(store, "add buy milk") == "added 1"
    assert run_line(store, "done 1") == "done 1"
    assert "[x]" in run_line(store, "show 1")


def test_cli_list_empty(store):
    assert run_line(store, "list") == "(empty)"


def test_cli_unknown_command(store):
    from errors import TodoError
    with pytest.raises(TodoError):
        run_line(store, "frobnicate")


def test_parse_error_on_done(store):
    with pytest.raises(ParseError):
        run_line(store, "done")


def test_tags_filter(store):
    store.add("buy milk", tags=["shopping"])
    store.add("write report", tags=["work"])
    items = store.all()
    assert len(by_tag(items, "shopping")) == 1
    assert len(by_tag(items, "work")) == 1


def test_search(store):
    store.add("buy milk")
    store.add("buy bread")
    store.add("write report")
    assert len(search(store.all(), "buy")) == 2


def test_format_count(store):
    store.add("a")
    store.add("b")
    store.mark_done(1)
    assert format_count(store.all()) == "1 done / 1 open / 2 total"
