import sys
from store import Store
from parser import parse
from commands import HANDLERS
from errors import TodoError


def run_line(store: Store, line: str) -> str:
    cmd, args = parse(line)
    handler = HANDLERS.get(cmd)
    if handler is None:
        raise TodoError(f"unknown command: {cmd}")
    return handler(store, args)


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    store = Store()
    if not argv:
        print("usage: todo <add|done|list|remove|show> ...")
        return 64
    line = " ".join(argv)
    try:
        result = run_line(store, line)
    except TodoError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
