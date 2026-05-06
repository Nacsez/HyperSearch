from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from hypersearch_api.auth import require_access
from hypersearch_api.schemas.history import (
    HistoryRecord,
    HistoryRetentionRequest,
    HistoryRetentionResponse,
)

router = APIRouter(prefix="/v1/history", tags=["history"])


def _record_to_schema(record) -> HistoryRecord:
    return HistoryRecord(
        history_id=record.history_id,
        kind=record.kind,
        query=record.query,
        request=record.request_payload,
        response=record.response_payload,
        debug=record.debug_payload,
        created_at=record.created_at.isoformat(),
    )


@router.get("", response_model=list[HistoryRecord], dependencies=[Depends(require_access)])
async def list_history(
    request: Request,
    kind: str | None = Query(default=None, pattern="^(search|research)$"),
    q: str | None = Query(default=None, max_length=200),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
):
    records = await asyncio.to_thread(
        request.app.state.database.list_history,
        kind=kind,
        query=q,
        limit=limit,
        offset=offset,
    )
    return [_record_to_schema(record) for record in records]


@router.get("/export", dependencies=[Depends(require_access)])
async def export_history(request: Request):
    return {
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "records": await asyncio.to_thread(request.app.state.database.export_history),
    }


@router.delete("/{history_id}", dependencies=[Depends(require_access)])
async def delete_history(history_id: str, request: Request):
    deleted = await asyncio.to_thread(
        request.app.state.database.delete_history,
        history_id,
    )
    if not deleted:
        raise HTTPException(status_code=404, detail="History record not found")
    return {"status": "ok", "deleted": 1}


@router.post(
    "/retention",
    response_model=HistoryRetentionResponse,
    dependencies=[Depends(require_access)],
)
async def apply_retention(body: HistoryRetentionRequest, request: Request):
    cutoff = datetime.now(timezone.utc) - timedelta(days=body.days)
    deleted = await asyncio.to_thread(
        request.app.state.database.delete_history_older_than,
        cutoff.isoformat(),
    )
    return HistoryRetentionResponse(deleted=deleted)

