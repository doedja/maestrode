class TodoError(Exception):
    pass


class NotFoundError(TodoError):
    def __init__(self, todo_id: int):
        super().__init__(f"todo {todo_id} not found")
        self.todo_id = todo_id


class ParseError(TodoError):
    pass


class ValidationError(TodoError):
    pass
