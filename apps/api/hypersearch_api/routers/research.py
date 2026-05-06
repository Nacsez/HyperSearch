from __future__ import annotations

import json

from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse

from hypersearch_api.auth import require_access
from hypersearch_api.schemas.research import (
    ResearchRequest,
    ResearchResponse,
    SessionTitleRequest,
    SessionTitleResponse,
)

router = APIRouter(prefix="/v1", tags=["research"])


def _sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=True)}\n\n"


@router.post("/research", response_model=ResearchResponse, dependencies=[Depends(require_access)])
async def research(request_model: ResearchRequest, request: Request):
    service = request.app.state.research_service
    if request_model.streaming:
        async def event_stream():
            yield _sse({"event": "research.start", "query": request_model.query})
            payload = await service.execute(request_model)
            yield _sse({"event": "research.result", "payload": payload})
            yield _sse({"event": "research.done"})

        return StreamingResponse(event_stream(), media_type="text/event-stream")
    return await service.execute(request_model)


@router.post("/session-title", response_model=SessionTitleResponse, dependencies=[Depends(require_access)])
async def session_title(request_model: SessionTitleRequest, request: Request):
    return await request.app.state.synthesize_service.title_session(
        query=request_model.query,
        context=request_model.context,
        provider_name=request_model.provider,
    )
