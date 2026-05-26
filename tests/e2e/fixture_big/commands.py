from store import Store
from parser import extract_tags, parse_id
from formatter import format_list
from errors import ParseError


def cmd_add(store: Store, args: list[str]) -> str:
    if not args:
        raise ParseError("add needs text")
    text, tags = extract_tags(args)
    new_id = store.add(text, tags=tags)
    return f"added {new_id}"


def cmd_done(store: Store, args: list[str]) -> str:
    if len(args) != 1:
        raise ParseError("done needs one id")
    todo_id = parse_id(args[0])
    store.mark_done(todo_id)
    return f"done {todo_id}"


def cmd_list(store: Store, args: list[str]) -> str:
    return format_list(store.all())


def cmd_remove(store: Store, args: list[str]) -> str:
    if len(args) != 1:
        raise ParseError("remove needs one id")
    todo_id = parse_id(args[0])
    store.remove(todo_id)
    return f"removed {todo_id}"


def cmd_show(store: Store, args: list[str]) -> str:
    if len(args) != 1:
        raise ParseError("show needs one id")
    todo_id = parse_id(args[0])
    todo = store.get(todo_id)
    return todo.display()


HANDLERS = {
    "add": cmd_add,
    "done": cmd_done,
    "list": cmd_list,
    "ls": cmd_list,
    "remove": cmd_remove,
    "rm": cmd_remove,
    "show": cmd_show,
}
