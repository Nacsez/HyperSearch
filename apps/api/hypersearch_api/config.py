from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
from typing import Iterable


def _parse_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _parse_int(value: str | None, default: int) -> int:
    if value is None or value == "":
        return default
    return int(value)


def _parse_csv(value: str | None) -> list[str]:
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def _load_dotenv(env_path: Path) -> None:
    if not env_path.exists():
        return
    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip("\"").strip("'"))


def _resolve_path(value: str, *, root: Path) -> Path:
    path = Path(value).expanduser()
    if path.is_absolute():
        return path
    return (root / path).resolve()


@dataclass(slots=True)
class Settings:
    app_name: str
    environment: str
    debug: bool
    debug_store_prompts: bool
    host: str
    port: int
    allow_origins: list[str]
    log_level: str
    sqlite_path: Path
    searxng_url: str
    valkey_url: str | None
    cache_ttl_search: int
    cache_ttl_page: int
    cache_ttl_extract: int
    cache_ttl_synthesis: int
    provider_default: str
    lmstudio_base_url: str
    lmstudio_model: str
    vllm_base_url: str | None
    vllm_model: str | None
    llamacpp_base_url: str | None
    llamacpp_model: str | None
    fetch_timeout_ms: int
    provider_timeout_ms: int
    enable_playwright_fallback: bool
    otel_enabled: bool
    lan_enabled: bool
    pairing_token: str | None
    fetch_user_agent: str
    fetch_concurrency: int
    request_timeout_ms: int
    max_query_length: int
    max_results_per_page: int
    max_pages: int
    max_research_top_n: int
    max_timeout_ms: int

    @property
    def is_network_exposed(self) -> bool:
        return self.host not in {"127.0.0.1", "localhost", "::1"}

    @classmethod
    def load(cls) -> "Settings":
        root = Path.cwd()
        _load_dotenv(root / ".env")
        sqlite_path = _resolve_path(
            os.getenv("HYPERSEARCH_SQLITE_PATH", "./data/hypersearch.db"),
            root=root,
        )
        sqlite_path.parent.mkdir(parents=True, exist_ok=True)
        return cls(
            app_name="HyperSearch",
            environment=os.getenv("HYPERSEARCH_ENV", "development"),
            debug=_parse_bool(os.getenv("HYPERSEARCH_DEBUG"), False),
            debug_store_prompts=_parse_bool(
                os.getenv("HYPERSEARCH_DEBUG_STORE_PROMPTS"), False
            ),
            host=os.getenv("HYPERSEARCH_HOST", "127.0.0.1"),
            port=_parse_int(os.getenv("HYPERSEARCH_PORT"), 8000),
            allow_origins=_parse_csv(os.getenv("HYPERSEARCH_ALLOW_ORIGINS")),
            log_level=os.getenv("HYPERSEARCH_LOG_LEVEL", "INFO").upper(),
            sqlite_path=sqlite_path,
            searxng_url=os.getenv("HYPERSEARCH_SEARXNG_URL", "http://127.0.0.1:8081"),
            valkey_url=os.getenv("HYPERSEARCH_VALKEY_URL") or None,
            cache_ttl_search=_parse_int(os.getenv("HYPERSEARCH_CACHE_TTL_SEARCH"), 120),
            cache_ttl_page=_parse_int(os.getenv("HYPERSEARCH_CACHE_TTL_PAGE"), 900),
            cache_ttl_extract=_parse_int(
                os.getenv("HYPERSEARCH_CACHE_TTL_EXTRACT"), 1800
            ),
            cache_ttl_synthesis=_parse_int(
                os.getenv("HYPERSEARCH_CACHE_TTL_SYNTHESIS"), 600
            ),
            provider_default=os.getenv("HYPERSEARCH_PROVIDER_DEFAULT", "lmstudio"),
            lmstudio_base_url=os.getenv(
                "HYPERSEARCH_LMSTUDIO_BASE_URL", "http://127.0.0.1:1234"
            ),
            lmstudio_model=os.getenv(
                "HYPERSEARCH_LMSTUDIO_MODEL", "qwen2.5-7b-instruct"
            ),
            vllm_base_url=os.getenv("HYPERSEARCH_VLLM_BASE_URL") or None,
            vllm_model=os.getenv("HYPERSEARCH_VLLM_MODEL") or None,
            llamacpp_base_url=os.getenv("HYPERSEARCH_LLAMACPP_BASE_URL") or None,
            llamacpp_model=os.getenv("HYPERSEARCH_LLAMACPP_MODEL") or None,
            fetch_timeout_ms=_parse_int(os.getenv("HYPERSEARCH_FETCH_TIMEOUT_MS"), 15000),
            provider_timeout_ms=_parse_int(
                os.getenv("HYPERSEARCH_PROVIDER_TIMEOUT_MS"), 45000
            ),
            enable_playwright_fallback=_parse_bool(
                os.getenv("HYPERSEARCH_ENABLE_PLAYWRIGHT_FALLBACK"), False
            ),
            otel_enabled=_parse_bool(os.getenv("HYPERSEARCH_OTEL_ENABLED"), False),
            lan_enabled=_parse_bool(os.getenv("HYPERSEARCH_LAN_ENABLED"), False),
            pairing_token=os.getenv("HYPERSEARCH_PAIRING_TOKEN") or None,
            fetch_user_agent=os.getenv(
                "HYPERSEARCH_FETCH_USER_AGENT",
                "HyperSearch/0.1 (+https://localhost)",
            ),
            fetch_concurrency=_parse_int(
                os.getenv("HYPERSEARCH_FETCH_CONCURRENCY"), 4
            ),
            request_timeout_ms=_parse_int(
                os.getenv("HYPERSEARCH_REQUEST_TIMEOUT_MS"), 30000
            ),
            max_query_length=_parse_int(
                os.getenv("HYPERSEARCH_MAX_QUERY_LENGTH"), 500
            ),
            max_results_per_page=_parse_int(
                os.getenv("HYPERSEARCH_MAX_RESULTS_PER_PAGE"), 50
            ),
            max_pages=_parse_int(os.getenv("HYPERSEARCH_MAX_PAGES"), 5),
            max_research_top_n=_parse_int(
                os.getenv("HYPERSEARCH_MAX_RESEARCH_TOP_N"), 250
            ),
            max_timeout_ms=_parse_int(os.getenv("HYPERSEARCH_MAX_TIMEOUT_MS"), 120000),
        )


def iter_local_hosts() -> Iterable[str]:
    return ("127.0.0.1", "::1", "localhost")
