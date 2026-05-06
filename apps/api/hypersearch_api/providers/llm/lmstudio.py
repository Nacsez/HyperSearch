from __future__ import annotations

import time

import httpx

from .base import BaseLLMProvider, LLMCompletion, LLMMessage, ProviderHealth


class LMStudioProvider(BaseLLMProvider):
    provider_name = "lmstudio"

    async def chat(
        self,
        *,
        messages: list[LLMMessage],
        temperature: float = 0.2,
        stream: bool = False,
        timeout_ms: int | None = None,
        max_tokens: int | None = None,
    ) -> LLMCompletion:
        if not self.base_url:
            raise RuntimeError("Provider base URL is not configured")
        if not self.model:
            raise RuntimeError("Provider model is not configured")
        payload = {
            "model": self.model,
            "messages": [{"role": item.role, "content": item.content} for item in messages],
            "temperature": temperature,
            "stream": stream,
        }
        if max_tokens is not None:
            payload["max_tokens"] = max_tokens
        headers = {"Content-Type": "application/json"}
        async with httpx.AsyncClient(timeout=(timeout_ms or self.timeout_ms) / 1000) as client:
            response = await client.post(
                f"{self.base_url.rstrip('/')}/v1/chat/completions",
                json=payload,
                headers=headers,
            )
            response.raise_for_status()
            body = response.json()
        content = (
            body.get("choices", [{}])[0]
            .get("message", {})
            .get("content", "")
            .strip()
        )
        return LLMCompletion(
            provider=self.provider_name,
            model=body.get("model", self.model),
            content=content,
            raw=body,
        )

    async def list_models(self) -> list[str]:
        if not self.base_url:
            return []
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(f"{self.base_url.rstrip('/')}/v1/models")
            response.raise_for_status()
            body = response.json()
        models = body.get("data", [])
        return [
            str(item.get("id"))
            for item in models
            if isinstance(item, dict) and item.get("id")
        ]

    async def healthcheck(self) -> ProviderHealth:
        if not self.base_url:
            return ProviderHealth(name=self.provider_name, ok=False, detail="not configured")
        started_at = time.perf_counter()
        try:
            models = await self.list_models()
        except Exception as exc:
            return ProviderHealth(name=self.provider_name, ok=False, detail=str(exc))
        if not self.model:
            return ProviderHealth(
                name=self.provider_name,
                ok=False,
                detail="model not configured; search is available but research synthesis is disabled",
                model_available=False,
                generation_ok=False,
                latency_ms=int((time.perf_counter() - started_at) * 1000),
                models=models,
            )
        if self.model not in models:
            return ProviderHealth(
                name=self.provider_name,
                ok=False,
                detail=f"preferred model is not loaded: {self.model}",
                model_available=False,
                generation_ok=False,
                latency_ms=int((time.perf_counter() - started_at) * 1000),
                models=models,
            )
        try:
            completion = await self.chat(
                messages=[
                    LLMMessage(role="system", content="Reply with only the word ok. Do not explain."),
                    LLMMessage(role="user", content="Say ok."),
                ],
                temperature=0.0,
                timeout_ms=12000,
                max_tokens=64,
            )
        except Exception as exc:
            return ProviderHealth(
                name=self.provider_name,
                ok=False,
                detail=f"model listed but generation smoke test failed: {exc}",
                model_available=True,
                generation_ok=False,
                latency_ms=int((time.perf_counter() - started_at) * 1000),
                models=models,
            )
        choices = completion.raw.get("choices") if isinstance(completion.raw, dict) else None
        usage = completion.raw.get("usage") if isinstance(completion.raw, dict) else None
        accepted_generation = bool(completion.content.strip()) or bool(choices) or bool(usage)
        return ProviderHealth(
            name=self.provider_name,
            ok=accepted_generation,
            detail=(
                "generation smoke test passed"
                if completion.content.strip()
                else "generation endpoint accepted the smoke test but returned no visible text"
            ),
            model_available=True,
            generation_ok=accepted_generation,
            latency_ms=int((time.perf_counter() - started_at) * 1000),
            models=models,
        )
