from __future__ import annotations

from .lmstudio import LMStudioProvider


class VLLMProvider(LMStudioProvider):
    provider_name = "vllm"

