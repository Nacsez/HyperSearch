FROM python:3.14-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY pyproject.toml /app/pyproject.toml
COPY hypersearch_api /app/hypersearch_api

RUN pip install --no-cache-dir --upgrade "pip>=26.1.1" "setuptools>=78.1.1" \
    && pip install --no-cache-dir ".[cache,extract,observability,playwright]"
RUN useradd --create-home --shell /usr/sbin/nologin hypersearch \
    && chown -R hypersearch:hypersearch /app

EXPOSE 8000

USER hypersearch

CMD ["uvicorn", "hypersearch_api.main:app", "--host", "0.0.0.0", "--port", "8000"]
