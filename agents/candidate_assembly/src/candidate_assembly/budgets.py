"""Budget dataclass, defaults, and the typed overflow signal.

Budgets are enforced in the tool layer (see ``fixture_tools.ToolBox``), not on the
model's honor system: every tool call decrements a counter and checks wall-clock,
argument bytes, and response bytes before returning. Exceeding any bound raises
``BudgetExceeded``, which an arm converts into a typed ``AssemblyError`` result.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Any

# A single tool call may never request more than this, regardless of what the
# model asks for. Clamped in the tool layer.
MAX_LIMIT_PER_CALL = 25

BUDGET_EXCEEDED_CODE = "BUDGET_EXCEEDED"


@dataclass(frozen=True)
class Budget:
    """Hard resource ceiling for one case × one arm."""

    max_tool_calls: int = 8
    max_model_calls: int = 10
    recursion_limit: int = 12
    max_candidates_in: int = 64
    max_recommendations: int = 10
    wall_clock_s: float = 180.0
    max_request_bytes: int = 48 * 1024
    max_response_bytes: int = 64 * 1024
    max_tokens_per_completion: int = 4096

    @classmethod
    def default(cls) -> "Budget":
        return cls()

    def with_overrides(self, **overrides: Any) -> "Budget":
        """Return a copy with the provided fields replaced, ignoring ``None`` so
        CLI flags that were not passed leave the default in place."""

        clean = {key: value for key, value in overrides.items() if value is not None}
        return replace(self, **clean)


class BudgetExceeded(Exception):
    """Raised by the tool layer when a call would breach a budget ceiling."""

    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(message)
