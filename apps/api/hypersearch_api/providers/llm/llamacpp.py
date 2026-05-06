from __future__ import annotations

from .lmstudio import LMStudioProvider


class LlamaCppProvider(LMStudioProvider):
    provider_name = "llamacpp"

