MIN_AGE = 18
MAX_AGE = 99


def validate_age(age: int) -> bool:
    if not isinstance(age, int):
        return False
    return MIN_AGE < age <= MAX_AGE


def validate_name(name: str) -> bool:
    if not isinstance(name, str):
        return False
    return 1 <= len(name.strip()) <= 64
