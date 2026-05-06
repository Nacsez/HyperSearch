from __future__ import annotations

import asyncio
import json

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse

from hypersearch_api.auth import require_access
from hypersearch_api.schemas.search import SearchPreset, SearchPresetCreate, SearchRequest, SearchResponse

router = APIRouter(prefix="/v1", tags=["search"])


def _sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=True)}\n\n"


@router.post("/search", response_model=SearchResponse, dependencies=[Depends(require_access)])
async def search(request_model: SearchRequest, request: Request):
    service = request.app.state.search_service
    if request_model.streaming:
        async def event_stream():
            yield _sse({"event": "search.start", "query": request_model.query})
            payload = await service.execute(request_model)
            yield _sse({"event": "search.result", "payload": payload})
            yield _sse({"event": "search.done"})

        return StreamingResponse(event_stream(), media_type="text/event-stream")
    return await service.execute(request_model)


@router.get("/search/presets", response_model=list[SearchPreset], dependencies=[Depends(require_access)])
async def list_presets(request: Request):
    presets = await asyncio.to_thread(request.app.state.database.list_presets)
    return [
        SearchPreset(
            preset_id=item.preset_id,
            name=item.name,
            request=item.payload,
            created_at=item.created_at.isoformat(),
        )
        for item in presets
    ]


@router.post("/search/presets", response_model=SearchPreset, dependencies=[Depends(require_access)])
async def save_preset(body: SearchPresetCreate, request: Request):
    preset = await asyncio.to_thread(
        request.app.state.database.save_preset,
        name=body.name,
        payload=body.request,
    )
    return SearchPreset(
        preset_id=preset.preset_id,
        name=preset.name,
        request=preset.payload,
        created_at=preset.created_at.isoformat(),
    )


@router.delete("/search/presets/{preset_id}", dependencies=[Depends(require_access)])
async def delete_preset(preset_id: str, request: Request):
    deleted = await asyncio.to_thread(request.app.state.database.delete_preset, preset_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Preset not found")
    return {"deleted": True, "preset_id": preset_id}
