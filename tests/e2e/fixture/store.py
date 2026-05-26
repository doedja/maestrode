from validator import validate_age, validate_name


class StoreError(ValueError):
    pass


_users: dict[str, int] = {}


def add_user(name: str, age: int) -> None:
    if not validate_name(name):
        raise StoreError(f"invalid name: {name!r}")
    if not validate_age(age):
        raise StoreError(f"invalid age: {age!r}")
    _users[name.strip()] = age


def get_user(name: str) -> int | None:
    return _users.get(name.strip())


def reset() -> None:
    _users.clear()
