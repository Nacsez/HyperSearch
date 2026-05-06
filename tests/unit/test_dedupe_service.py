from hypersearch_api.services.dedupe_service import DedupeService


def test_dedupe_service_collapses_duplicate_urls():
    service = DedupeService()
    results = [
      {"title": "Example", "url": "https://example.com/a?utm=1"},
      {"title": "Example", "url": "https://example.com/a?utm=2"},
      {"title": "Other", "url": "https://example.com/b"},
    ]

    deduped = service.dedupe(results)

    assert len(deduped) == 2

