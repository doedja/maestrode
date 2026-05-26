from datetime import datetime, timedelta
from models import Todo


def by_status(todos: list[Todo], done: bool) -> list[Todo]:
    return [t for t in todos if t.completed == done]


def by_tag(todos: list[Todo], tag: str) -> list[Todo]:
    return [t for t in todos if tag in t.tags]


def older_than(todos: list[Todo], days: int) -> list[Todo]:
    cutoff = datetime.now() - timedelta(days=days)
    return [t for t in todos if t.created_at < cutoff]


def search(todos: list[Todo], needle: str) -> list[Todo]:
    needle = needle.lower()
    return [t for t in todos if needle in t.text.lower()]
