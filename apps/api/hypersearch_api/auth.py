from __future__ import annotations

from hmac import compare_digest
import ipaddress

from fastapi import HTTPException, Request, status

from .config import Settings, iter_local_hosts


def _extract_pairing_token(request: Request) -> str | None:
    header_value = request.headers.get("x-hypersearch-token")
    if header_value:
        return header_value.strip()
    auth_header = request.headers.get("authorization", "")
    if auth_header.lower().startswith("bearer "):
        return auth_header[7:].strip()
    return None


def _client_host(request: Request) -> str | None:
    if _is_trusted_private_proxy(request):
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return request.client.host if request.client else None


def _direct_client_host(request: Request) -> str | None:
    return request.client.host if request.client else None


def _is_local_host(value: str | None) -> bool:
    if not value:
        return False
    if value in set(iter_local_hosts()):
        return True
    try:
        return ipaddress.ip_address(value).is_loopback
    except ValueError:
        return False


def _is_local_request(request: Request) -> bool:
    return _is_local_host(_client_host(request)) or _is_local_host(_direct_client_host(request))


def _is_trusted_private_proxy(request: Request) -> bool:
    proxy_marker = request.headers.get("x-hypersearch-proxy")
    client_host = _direct_client_host(request)
    if proxy_marker != "caddy" or not client_host:
        return False
    try:
        address = ipaddress.ip_address(client_host)
    except ValueError:
        return False
    if address.is_loopback:
        return True
    # The desktop-managed Caddy proxy reaches the API over Docker bridge
    # addresses. Do not trust arbitrary RFC1918 LAN clients that spoof the
    # proxy marker header.
    return address in ipaddress.ip_network("172.16.0.0/12")


def _is_private_client(request: Request) -> bool:
    client_host = _client_host(request)
    if not client_host:
        return False
    try:
        return ipaddress.ip_address(client_host).is_private
    except ValueError:
        return client_host.endswith(".local") or client_host == "localhost"


def _is_trusted_local_proxy_request(request: Request) -> bool:
    """Allow the desktop-managed localhost proxy to behave like local access.

    Browser requests normally enter the API through Caddy. Inside Docker, that
    direct client is a private bridge address, not 127.0.0.1, so we trust the
    explicit proxy marker only while HyperSearch is still bound for local-only
    use. LAN mode still requires a pairing token.
    """
    return _is_trusted_private_proxy(request)


def _token_matches(token: str | None, expected: str | None) -> bool:
    if not token or not expected:
        return False
    return compare_digest(token, expected)


async def require_access(request: Request) -> None:
    settings: Settings = request.app.state.settings
    if _is_local_request(request):
        return
    if not settings.lan_enabled and _is_trusted_local_proxy_request(request):
        return
    if not settings.lan_enabled:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="LAN access is disabled. Use the local desktop app to enable paired LAN access.",
        )
    if not _is_private_client(request):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="HyperSearch only supports local network access when LAN mode is enabled.",
        )
    if _token_matches(_extract_pairing_token(request), settings.pairing_token):
        return
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Pairing token required for LAN access",
    )


async def require_local_access(request: Request) -> None:
    if _is_local_request(request):
        return
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="This administrative operation is only available from the local HyperSearch app.",
    )
