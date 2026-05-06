from __future__ import annotations

import argparse
import asyncio
from time import perf_counter

import httpx


async def worker(client: httpx.AsyncClient, url: str, payload: dict, headers: dict[str, str]) -> float:
    start = perf_counter()
    response = await client.post(url, json=payload, headers=headers)
    response.raise_for_status()
    return perf_counter() - start


async def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark HyperSearch search latency")
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--requests", type=int, default=10)
    parser.add_argument("--concurrency", type=int, default=2)
    parser.add_argument("--query", default="hypersearch benchmark")
    parser.add_argument("--api-key", default="")
    args = parser.parse_args()

    payload = {
        "query": args.query,
        "results_per_page": 5,
        "max_pages": 1,
        "page": 1,
        "safe_search": 1,
        "dedupe": True,
        "fetch_pages": False,
        "extract_text": False,
        "summarize": False,
        "streaming": False,
        "cache_policy": "bypass",
    }
    headers = {"X-API-Key": args.api_key} if args.api_key else {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        timings: list[float] = []
        for batch_start in range(0, args.requests, args.concurrency):
            batch_size = min(args.concurrency, args.requests - batch_start)
            batch = [
                worker(client, f"{args.base_url}/v1/search", payload, headers)
                for _ in range(batch_size)
            ]
            timings.extend(await asyncio.gather(*batch))

    total = sum(timings)
    print(f"requests={len(timings)} total_s={total:.3f} avg_s={total / len(timings):.3f} max_s={max(timings):.3f}")


if __name__ == "__main__":
    asyncio.run(main())

