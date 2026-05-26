import store


def register(name: str, age: int) -> None:
    store.add_user(name, age)


def lookup(name: str) -> int | None:
    return store.get_user(name)
