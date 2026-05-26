from errors import ParseError


def parse(line: str) -> tuple[str, list[str]]:
    """Parse 'cmd arg1 arg2 ...' into (cmd, args). Supports tag syntax #foo."""
    line = (line or "").strip()
    if not line:
        raise ParseError("empty input")
    parts = line.split()
    cmd = parts[0].lower()
    args = parts[1:]
    return cmd, args


def extract_tags(args: list[str]) -> tuple[str, list[str]]:
    text_parts: list[str] = []
    tags: list[str] = []
    for a in args:
        if a.startswith("#") and len(a) > 1:
            tags.append(a[1:])
        else:
            text_parts.append(a)
    return " ".join(text_parts), tags


def parse_id(arg: str) -> int:
    try:
        return int(arg)
    except ValueError as e:
        raise ParseError(f"expected integer id, got {arg!r}") from e
