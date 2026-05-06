from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass(slots=True)
class LLMMessage:
    role: str
    content: str


@dataclass(slots=True)
class LLMCompletion:
    provider: str
    model: str | None
    content: str
    raw: dict


@dataclass(slots=True)
class ProviderHealth:
    name: str
    ok: bool
    detail: str
    model_available: bool | None = None
    generation_ok: bool | None = None
    latency_ms: int | None = None
    models: list[str] | None = None


class BaseLLMProvider(ABC):
    provider_name: str = "base"

    def __init__(
        self,
        *,
        base_url: str | None,
        model: str | None,
        timeout_ms: int = 45000,
    ) -> None:
        self.base_url = base_url
        self.model = model
        self.timeout_ms = timeout_ms

    @abstractmethod
    async def chat(
        self,
        *,
        messages: list[LLMMessage],
        temperature: float = 0.2,
        stream: bool = False,
        timeout_ms: int | None = None,
        max_tokens: int | None = None,
    ) -> LLMCompletion:
        raise NotImplementedError

    @abstractmethod
    async def healthcheck(self) -> ProviderHealth:
        raise NotImplementedError

    @abstractmethod
    async def list_models(self) -> list[str]:
        raise NotImplementedError
