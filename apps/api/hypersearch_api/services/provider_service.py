from __future__ import annotations

import ipaddress
import logging
import time
from urllib.parse import urlparse

from hypersearch_api.config import Settings
from hypersearch_api.exceptions import ProviderModelUnavailableError, ProviderUnavailableError
from hypersearch_api.providers.llm.base import BaseLLMProvider, LLMMessage, ProviderHealth
from hypersearch_api.providers.llm.llamacpp import LlamaCppProvider
from hypersearch_api.providers.llm.lmstudio import LMStudioProvider
from hypersearch_api.providers.llm.vllm import VLLMProvider
from hypersearch_api.storage.sqlite import Database

logger = logging.getLogger(__name__)

_LOCAL_PROVIDER_HOSTS = {"127.0.0.1", "localhost", "::1", "host.docker.internal"}
_HEALTH_CACHE_TTL_SECONDS = 60.0


def _is_local_provider_url(value: str | None) -> bool:
    if not value:
        return True
    parsed = urlparse(value)
    host = parsed.hostname
    if not host:
        return False
    if host in _LOCAL_PROVIDER_HOSTS:
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return host.endswith(".local")
    return address.is_loopback or address.is_private


class ProviderService:
    def __init__(self, settings: Settings, database: Database) -> None:
        self.settings = settings
        self.database = database
        self._providers: dict[str, BaseLLMProvider] = {}
        self._health_cache: dict[str, tuple[float, ProviderHealth]] = {}

    async def initialize(self) -> None:
        self._seed_defaults()
        self._reload()

    def get_llm_settings(self) -> dict:
        enabled_record = self.database.get_app_setting("llm_enabled")
        reason_record = self.database.get_app_setting("llm_disabled_reason")
        enabled = (
            bool(enabled_record["value"])
            if enabled_record is not None
            else self.settings.llm_enabled
        )
        reason = (
            reason_record["value"]
            if reason_record is not None
            else self.settings.llm_disabled_reason
        )
        return {
            "enabled": enabled,
            "reason": reason if not enabled else None,
            "source": (
                enabled_record["source"]
                if enabled_record is not None
                else self.settings.llm_settings_source
            ),
        }

    def set_llm_settings(self, *, enabled: bool, reason: str | None = None) -> dict:
        self.database.set_app_setting("llm_enabled", enabled, source="app")
        self.database.set_app_setting(
            "llm_disabled_reason",
            None if enabled else reason,
            source="app",
        )
        return self.get_llm_settings()

    def is_llm_enabled(self) -> bool:
        return bool(self.get_llm_settings()["enabled"])

    async def llm_capability(self) -> dict:
        state = self.get_llm_settings()
        default_name = self.database.get_default_provider_name() or "lmstudio"
        record = self.database.get_provider_config(default_name)
        base = {
            "enabled": bool(state["enabled"]),
            "ready": False,
            "mode": "local",
            "detail": state.get("reason") or "LLM features are disabled",
            "provider": default_name,
            "base_url": record.base_url if record else None,
            "model": record.model if record else None,
            "models": None,
        }
        if not state["enabled"]:
            base["mode"] = "disabled"
            return base
        if record is None:
            base["detail"] = f"Unknown provider: {default_name}"
            return base
        if not record.enabled or not record.base_url:
            base["detail"] = "Default provider is not configured"
            return base
        try:
            health = await self._provider_health(default_name)
        except Exception as exc:
            logger.exception("LLM readiness check failed")
            base["detail"] = str(exc)
            return base
        base.update(
            {
                "ready": bool(health.ok),
                "detail": health.detail,
                "model_available": health.model_available,
                "generation_ok": health.generation_ok,
                "latency_ms": health.latency_ms,
                "models": health.models,
            }
        )
        return base

    def _seed_defaults(self) -> None:
        current_default = self.database.get_default_provider_name() or self.settings.provider_default
        if current_default not in {"lmstudio", "vllm", "llamacpp"}:
            current_default = self.settings.provider_default
        defaults = [
            (
                "lmstudio",
                "LM Studio",
                "openai-compatible",
                self.settings.lmstudio_base_url,
                self.settings.lmstudio_model,
            ),
            (
                "vllm",
                "vLLM",
                "openai-compatible",
                self.settings.vllm_base_url,
                self.settings.vllm_model,
            ),
            (
                "llamacpp",
                "llama.cpp",
                "openai-compatible",
                self.settings.llamacpp_base_url,
                self.settings.llamacpp_model,
            ),
        ]
        for name, display_name, provider_type, base_url, model in defaults:
            if self.database.get_provider_config(name) is not None:
                continue
            self.database.upsert_provider_config(
                name=name,
                display_name=display_name,
                provider_type=provider_type,
                base_url=base_url,
                model=model,
                enabled=bool(base_url) and _is_local_provider_url(base_url),
                is_default=name == current_default,
                metadata={},
            )

    def _reload(self) -> None:
        self._providers = {}
        self._health_cache = {}
        for record in self.database.list_provider_configs():
            provider_cls: type[BaseLLMProvider]
            if record.name == "lmstudio":
                provider_cls = LMStudioProvider
            elif record.name == "vllm":
                provider_cls = VLLMProvider
            elif record.name == "llamacpp":
                provider_cls = LlamaCppProvider
            else:
                continue
            self._providers[record.name] = provider_cls(
                base_url=record.base_url,
                model=record.model,
                timeout_ms=self.settings.provider_timeout_ms,
            )

    def _provider_class_for_name(self, name: str) -> type[BaseLLMProvider]:
        if name == "vllm":
            return VLLMProvider
        if name == "llamacpp":
            return LlamaCppProvider
        return LMStudioProvider

    def _draft_provider(
        self,
        *,
        name: str,
        base_url: str | None,
        model: str | None,
        enabled: bool,
    ) -> BaseLLMProvider:
        if not enabled or not base_url:
            raise ProviderUnavailableError(
                f"Local provider is not configured: {name}",
                details={
                    "provider": name,
                    "remediation": "Set a local OpenAI-compatible endpoint before testing.",
                },
            )
        if not _is_local_provider_url(base_url):
            raise ProviderUnavailableError(
                "Provider endpoint must be local or private-network scoped",
                details={"provider": name, "base_url": base_url},
            )
        return self._provider_class_for_name(name)(
            base_url=base_url,
            model=model,
            timeout_ms=self.settings.provider_timeout_ms,
        )

    async def _provider_health(self, name: str, *, force: bool = False) -> ProviderHealth:
        if not force:
            cached = self._health_cache.get(name)
            if cached and (time.monotonic() - cached[0]) < _HEALTH_CACHE_TTL_SECONDS:
                return cached[1]
        provider = self._providers[name]
        health = await provider.healthcheck()
        self._health_cache[name] = (time.monotonic(), health)
        return health

    def resolve(self, name: str | None = None) -> BaseLLMProvider:
        provider_name = name or self.database.get_default_provider_name() or "lmstudio"
        provider = self._providers.get(provider_name)
        if provider is None:
            raise KeyError(f"Unknown provider: {provider_name}")
        return provider

    async def list_providers(self) -> list[dict]:
        output: list[dict] = []
        default_name = self.database.get_default_provider_name()
        for record in self.database.list_provider_configs():
            healthy = None
            detail = None
            generation_ok = None
            model_available = None
            latency_ms = None
            models = None
            if record.enabled:
                health = await self._provider_health(record.name)
                healthy = health.ok
                detail = health.detail
                generation_ok = health.generation_ok
                model_available = health.model_available
                latency_ms = health.latency_ms
                models = health.models
            output.append(
                {
                    "name": record.name,
                    "display_name": record.display_name,
                    "provider_type": record.provider_type,
                    "base_url": record.base_url,
                    "model": record.model,
                    "enabled": record.enabled,
                    "is_default": record.name == default_name,
                    "healthy": healthy,
                    "detail": detail,
                    "generation_ok": generation_ok,
                    "model_available": model_available,
                    "latency_ms": latency_ms,
                    "models": models,
                }
            )
        return output

    async def test_provider(
        self,
        *,
        name: str,
        base_url: str | None = None,
        model: str | None = None,
        enabled: bool | None = None,
    ) -> dict:
        record = self.database.get_provider_config(name)
        draft_mode = base_url is not None or model is not None or enabled is not None
        if draft_mode:
            effective_enabled = True if enabled is None else enabled
            try:
                provider = self._draft_provider(
                    name=name,
                    base_url=base_url,
                    model=model,
                    enabled=effective_enabled,
                )
                health = await provider.healthcheck()
            except Exception as exc:
                logger.exception("Draft provider test failed")
                return {
                    "ok": False,
                    "detail": str(exc),
                    "provider": name,
                    "base_url": base_url,
                    "model": model,
                }
        else:
            try:
                provider = self.resolve(name)
            except KeyError as exc:
                return {"ok": False, "detail": str(exc), "provider": name}
            health = await self._provider_health(name, force=True)
            if record is not None:
                base_url = record.base_url
                model = record.model
        if not health.ok:
            return {
                "ok": False,
                "detail": health.detail,
                "provider": name,
                "base_url": base_url,
                "model": model,
                "model_available": health.model_available,
                "generation_ok": health.generation_ok,
                "latency_ms": health.latency_ms,
                "models": health.models,
            }
        try:
            completion = await provider.chat(
                messages=[LLMMessage(role="user", content="Reply with the single word pong.")],
            )
        except Exception as exc:
            logger.exception("Provider test failed")
            return {
                "ok": False,
                "detail": str(exc),
                "provider": name,
                "base_url": base_url,
                "model": model,
                "model_available": health.model_available,
                "generation_ok": False,
                "latency_ms": health.latency_ms,
                "models": health.models,
            }
        return {
            "ok": True,
            "detail": completion.content or "ok",
            "provider": name,
            "base_url": base_url,
            "model": completion.model or model,
            "model_available": health.model_available,
            "generation_ok": True,
            "latency_ms": health.latency_ms,
            "models": health.models,
        }

    async def list_provider_models(self, name: str) -> dict:
        record = self.database.get_provider_config(name)
        if record is None:
            raise ProviderUnavailableError(
                f"Unknown local provider: {name}",
                details={"provider": name},
            )
        if not record.enabled or not record.base_url:
            raise ProviderUnavailableError(
                f"Local provider is not configured: {name}",
                details={
                    "provider": name,
                    "remediation": "Set a local OpenAI-compatible endpoint first.",
                },
            )
        try:
            models = await self.resolve(name).list_models()
        except Exception as exc:
            logger.exception("Provider model discovery failed")
            raise ProviderUnavailableError(
                f"Could not list models from {name}",
                details={
                    "provider": name,
                    "base_url": record.base_url,
                    "detail": str(exc),
                    "remediation": "Start the local provider server and confirm the endpoint exposes /v1/models.",
                },
            ) from exc
        return {"provider": name, "base_url": record.base_url, "models": models}

    async def list_draft_provider_models(
        self,
        *,
        name: str,
        base_url: str | None,
        model: str | None = None,
        enabled: bool = True,
    ) -> dict:
        provider = self._draft_provider(
            name=name,
            base_url=base_url,
            model=model,
            enabled=enabled,
        )
        try:
            models = await provider.list_models()
        except Exception as exc:
            logger.exception("Draft provider model discovery failed")
            raise ProviderUnavailableError(
                f"Could not list models from {name}",
                details={
                    "provider": name,
                    "base_url": base_url,
                    "detail": str(exc),
                    "remediation": "Start the local provider server and confirm the endpoint exposes /v1/models.",
                },
            ) from exc
        return {"provider": name, "base_url": base_url, "models": models}

    async def set_default_provider(self, name: str) -> None:
        try:
            self.database.set_default_provider(name)
        except ValueError as exc:
            raise ProviderUnavailableError(str(exc), details={"provider": name}) from exc
        self._reload()

    async def update_provider_profile(
        self,
        *,
        name: str,
        display_name: str,
        provider_type: str,
        base_url: str | None,
        model: str | None,
        enabled: bool,
        is_default: bool,
    ) -> dict:
        if not _is_local_provider_url(base_url):
            raise ProviderUnavailableError(
                "Provider endpoint must be local or private-network scoped",
                details={"provider": name, "base_url": base_url},
            )
        if is_default and (not enabled or not base_url):
            raise ProviderUnavailableError(
                "Default provider must be enabled and have a local endpoint",
                details={"provider": name},
            )
        try:
            record = self.database.update_provider_profile(
                name=name,
                display_name=display_name,
                provider_type=provider_type,
                base_url=base_url,
                model=model,
                enabled=enabled,
                is_default=is_default,
            )
        except ValueError as exc:
            raise ProviderUnavailableError(str(exc), details={"provider": name}) from exc
        self._reload()
        return {
            "name": record.name,
            "display_name": record.display_name,
            "provider_type": record.provider_type,
            "base_url": record.base_url,
            "model": record.model,
            "enabled": record.enabled,
            "is_default": record.is_default,
        }

    async def ensure_model_available(self, name: str | None = None) -> dict:
        if not self.is_llm_enabled():
            state = self.get_llm_settings()
            raise ProviderUnavailableError(
                "LLM features are disabled",
                details={
                    "provider": name,
                    "reason": state.get("reason"),
                    "remediation": "Enable LLM features in Operations before running synthesis.",
                },
            )
        provider_name = name or self.database.get_default_provider_name() or "lmstudio"
        return await self.verify_model_available(provider_name)

    async def verify_model_available(
        self,
        name: str,
        *,
        base_url: str | None = None,
        model: str | None = None,
        enabled: bool | None = None,
    ) -> dict:
        draft_mode = base_url is not None or model is not None or enabled is not None
        if draft_mode:
            provider = self._draft_provider(
                name=name,
                base_url=base_url,
                model=model,
                enabled=True if enabled is None else enabled,
            )
            try:
                models = await provider.list_models()
            except Exception as exc:
                raise ProviderUnavailableError(
                    f"Could not list models from {name}",
                    details={
                        "provider": name,
                        "base_url": base_url,
                        "detail": str(exc),
                        "remediation": "Start the local provider server and confirm the endpoint exposes /v1/models.",
                    },
                ) from exc
            if model and model not in models:
                raise ProviderModelUnavailableError(
                    f"Preferred model is not available on {name}: {model}",
                    details={
                        "provider": name,
                        "base_url": base_url,
                        "preferred_model": model,
                        "available_models": models,
                        "remediation": "Load the selected model in the local provider or choose an available model.",
                    },
                )
            return {
                "provider": name,
                "base_url": base_url,
                "model": model,
                "available_models": models,
            }
        provider_name = name
        record = self.database.get_provider_config(provider_name)
        if record is None:
            raise ProviderUnavailableError(
                f"Unknown local provider: {provider_name}",
                details={"provider": provider_name},
            )
        if not record.enabled or not record.base_url:
            raise ProviderUnavailableError(
                f"Local provider is not configured: {provider_name}",
                details={
                    "provider": provider_name,
                    "remediation": "Configure a local LM Studio, vLLM, or llama.cpp endpoint in provider settings.",
                },
            )
        provider = self.resolve(provider_name)
        health = await self._provider_health(provider_name, force=True)
        if not health.ok:
            if health.model_available is False and record.model:
                raise ProviderModelUnavailableError(
                    f"Preferred model is not available on {provider_name}: {record.model}",
                    details={
                        "provider": provider_name,
                        "base_url": record.base_url,
                        "preferred_model": record.model,
                        "available_models": health.models or [],
                        "detail": health.detail,
                        "remediation": "Load the preferred model in the local provider or update the provider profile.",
                    },
                )
            raise ProviderUnavailableError(
                f"Local provider is unreachable: {provider_name}",
                details={
                    "provider": provider_name,
                    "base_url": record.base_url,
                    "detail": health.detail,
                    "remediation": "Start the local provider server and confirm its endpoint matches the saved profile.",
                },
            )
        models = await provider.list_models()
        if record.model and record.model not in models:
            raise ProviderModelUnavailableError(
                f"Preferred model is not available on {provider_name}: {record.model}",
                details={
                    "provider": provider_name,
                    "base_url": record.base_url,
                    "preferred_model": record.model,
                    "available_models": models,
                    "remediation": "Load the preferred model in the local provider or update the provider profile.",
                },
            )
        return {
            "provider": provider_name,
            "base_url": record.base_url,
            "model": record.model,
            "available_models": models,
        }
