from models import Todo


def format_list(todos: list[Todo]) -> str:
    if not todos:
        return "(empty)"
    return "\n".join(t.display() for t in todos)


def format_short(todo: Todo) -> str:
    return f"#{todo.id} {todo.text[:40]}"


def format_count(todos: list[Todo]) -> str:
    done = sum(1 for t in todos if t.completed)
    return f"{done} done / {len(todos) - done} open / {len(todos)} total"
