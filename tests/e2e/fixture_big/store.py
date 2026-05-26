from models import Todo
from errors import NotFoundError, ValidationError


class Store:
    def __init__(self) -> None:
        self._items: list[Todo] = []

    def add(self, text: str, tags: list[str] | None = None) -> int:
        text = (text or "").strip()
        if not text:
            raise ValidationError("text cannot be empty")
        new_id = len(self._items) + 1
        todo = Todo(id=new_id, text=text, tags=list(tags or []))
        self._items.append(todo)
        return new_id

    def get(self, todo_id: int) -> Todo:
        if todo_id < 1 or todo_id > len(self._items):
            raise NotFoundError(todo_id)
        return self._items[todo_id]

    def mark_done(self, todo_id: int) -> None:
        todo = self.get(todo_id)
        todo.completed = True

    def remove(self, todo_id: int) -> None:
        if todo_id < 1 or todo_id > len(self._items):
            raise NotFoundError(todo_id)
        del self._items[todo_id - 1]
        for i, t in enumerate(self._items, start=1):
            t.id = i

    def all(self) -> list[Todo]:
        return list(self._items)

    def reset(self) -> None:
        self._items.clear()
