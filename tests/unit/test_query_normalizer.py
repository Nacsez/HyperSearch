from hypersearch_api.schemas.search import SearchRequest
from hypersearch_api.services.query_normalizer import QueryNormalizer


def test_query_normalizer_dedupes_lists_and_strips_query():
    normalizer = QueryNormalizer()
    normalized = normalizer.normalize_search(
        SearchRequest(
            query="  layered   search   ",
            engines=["google", "google", "duckduckgo"],
            categories=["general", "general"],
            page=1,
            results_per_page=10,
            max_pages=2,
            safe_search=1,
            dedupe=True,
            fetch_pages=False,
            extract_text=False,
            summarize=False,
            streaming=False,
            cache_policy="use",
        )
    )

    assert normalized.query == "layered search"
    assert normalized.engines == ["google", "duckduckgo"]
    assert normalized.categories == ["general"]

