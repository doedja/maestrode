from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class Todo:
    id: int
    text: str
    completed: bool = False
    created_at: datetime = field(default_factory=datetime.now)
    tags: list[str] = field(default_factory=list)

    def display(self) -> str:
        mark = "[x]" if self.completed else "[ ]"
        tags = f" ({', '.join(self.tags)})" if self.tags else ""
        return f"{self.id}. {mark} {self.text}{tags}"
