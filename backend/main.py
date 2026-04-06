"""
JanSahayak – FastAPI backend  (v4.0)
-------------------------------------
POST /annotate
  • Accepts: multipart/form-data  { image, query, device_id? }
  • Checks query clarity with Gemini — if unclear returns a clarification question.
  • If clear: runs full pipeline and returns annotated result.

POST /clarify
  • Accepts: JSON { session_id, answer, device_id? }
  • Resumes a session after the user answers the clarification question.
  • Runs the full pipeline with enriched context.
"""
from __future__ import annotations

import base64
import logging
import uuid
from typing import Optional

from dotenv import load_dotenv

logging.basicConfig(level=logging.DEBUG)

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

load_dotenv()  # must run before service imports so env vars are available

from services.device_service import DeviceService
from services.gemini_service import GeminiService
from services.neo4j_service import Neo4jService
from services.session_service import SessionService
from services.speech_service import SpeechService
from services.supabase_service import SupabaseService
from services.vision_service import VisionService

log = logging.getLogger(__name__)

# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(title="JanSahayak API", version="4.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Service singletons ────────────────────────────────────────────────────────

try:
    _supabase = SupabaseService()
    _neo4j    = Neo4jService()
    _vision   = VisionService()
    _gemini   = GeminiService()
    _speech   = SpeechService()
    _device   = DeviceService(_supabase)
    _sessions = SessionService()
except Exception as exc:
    raise RuntimeError(f"Service initialisation failed: {exc}") from exc


@app.on_event("startup")
async def _on_startup() -> None:
    await _neo4j.verify_connectivity()
    await _neo4j.ensure_indexes()


@app.on_event("shutdown")
async def _on_shutdown() -> None:
    await _neo4j.close()


# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "version": "4.0.0",
        "gemini": _gemini.available,
        "azure_speech": _speech.available,
    }


# ── Pipeline helper ───────────────────────────────────────────────────────────

async def _run_pipeline(
    image_bytes: bytes,
    query: str,
    device_id: str,
    session_id: str,
    conversation_id: str,
    prev_query_en: Optional[str] = None,
    turn: int = 1,
    language: str = "en-IN",
) -> dict:
    """
    Full annotation pipeline. Returns the JSON response dict.
    Raises HTTPException on hard failures.
    """
    unique = str(uuid.uuid4())

    # ── Step 1: Translate query to English (must be first) ────────────────────
    if language not in ("en-IN", "en-US"):
        query_en = await asyncio.to_thread(_gemini.to_english, query)
        log.info("[pipeline] translated query: %r → %r", query, query_en)
    else:
        query_en = query

    # ── Step 2: Parallel — upload original + YOLO + Gemini highlight ──────────
    original_path = f"original/{device_id}/{unique}.jpg"

    results = await asyncio.gather(
        asyncio.to_thread(_supabase.upload_image, original_path, image_bytes),
        asyncio.to_thread(_vision.detect_labels, image_bytes),
        asyncio.to_thread(_gemini.highlight_query, image_bytes, query_en),
        return_exceptions=True,
    )

    if isinstance(results[0], Exception):
        raise HTTPException(status_code=502, detail=f"Supabase upload failed: {results[0]}")
    if isinstance(results[1], Exception):
        raise HTTPException(status_code=500, detail=f"Vision service failed: {results[1]}")

    original_url: str = results[0]
    yolo_labels: list = results[1]
    gemini_annotated, gemini_labels = results[2] if not isinstance(results[2], Exception) else (image_bytes, [])

    annotated_bytes = gemini_annotated if gemini_labels else image_bytes
    detected_objects = list(dict.fromkeys(yolo_labels + gemini_labels))

    # ── Step 3: Parallel — upload annotated + fetch RAG context ──────────────
    annotated_path = f"annotated/{device_id}/{unique}.jpg"

    step3 = await asyncio.gather(
        asyncio.to_thread(_supabase.upload_image, annotated_path, annotated_bytes),
        _neo4j.get_rag_context(device_id=device_id, session_id=session_id, current_objects=detected_objects),
        return_exceptions=True,
    )

    if isinstance(step3[0], Exception):
        raise HTTPException(status_code=502, detail=f"Supabase upload failed: {step3[0]}")

    annotated_url: str = step3[0]
    rag_context: str = step3[1] if not isinstance(step3[1], Exception) else ""
    if rag_context:
        log.info("[RAG] %d chars injected for device=%s", len(rag_context), device_id[:8])

    # ── Step 4: Gemini explanation — critical path, user waits for this ───────
    explanation = await asyncio.to_thread(
        _gemini.explain,
        image_bytes,
        query,
        detected_objects,
        language,
        rag_context,
    )

    # ── Step 5: Fire-and-forget — DB writes after response is ready ───────────
    async def _post_process():
        try:
            query_id = await asyncio.to_thread(
                _supabase.create_query,
                device_id, query, conversation_id, explanation,
            )
            if turn == 1:
                await asyncio.to_thread(_supabase.touch_conversation, conversation_id, query)
            else:
                await asyncio.to_thread(_supabase.touch_conversation, conversation_id)
            await asyncio.to_thread(
                _supabase.create_image_record, device_id, query_id, original_url, annotated_url
            )
            explanation_en = await asyncio.to_thread(_gemini.to_english, explanation)
            keywords = await asyncio.to_thread(_gemini.extract_keywords, query_en, explanation_en)
            await _neo4j.record_interaction(
                device_id=device_id, query_id=query_id, query_text=query_en,
                response_text=explanation_en, image_url=original_url,
                keywords=keywords, session_id=session_id,
                prev_query_text=prev_query_en, turn=turn,
            )
        except Exception as exc:
            log.error("[post_process] error: %s", exc, exc_info=True)

    asyncio.create_task(_post_process())

    # Use a placeholder query_id/image_id in the response — DB writes happen async
    query_id = str(uuid.uuid4())
    image_id = str(uuid.uuid4())

    b64 = base64.b64encode(annotated_bytes).decode("utf-8")

    return {
        "session_id": session_id,
        "conversation_id": conversation_id,
        "needs_clarification": False,
        "clarification_question": "",
        "device_id": device_id,
        "query_id": query_id,
        "image_id": image_id,
        "original_url": original_url,
        "annotated_url": annotated_url,
        "detected_objects": detected_objects,
        "annotated_image_base64": f"data:image/jpeg;base64,{b64}",
        "explanation": explanation,
    }


# ── Routes ────────────────────────────────────────────────────────────────────

@app.post("/annotate")
async def annotate(
    image: UploadFile = File(..., description="JPEG/PNG image to analyse"),
    query: str = Form(default="Describe what you see"),
    device_id: Optional[str] = Form(default=None),
    conversation_id: Optional[str] = Form(default=None),
    language: str = Form(default="en-IN"),
):
    """
    Entry point. Checks clarity first.
    If unclear → returns clarification question and stores session.
    If clear   → runs full pipeline immediately.
    """
    device_id, is_new_device = _device.get_or_create(device_id)
    conversation_id = _supabase.ensure_conversation(device_id, conversation_id)
    image_bytes = await image.read()
    if not image_bytes:
        raise HTTPException(status_code=400, detail="Empty image file.")

    # ── Clarity check ─────────────────────────────────────────────────────────
    is_clear, clarification_question = _gemini.check_clarity(image_bytes, query)

    if not is_clear:
        session_id = _sessions.create(
            device_id,
            image_bytes,
            query,
            language,
            conversation_id=conversation_id,
        )
        _sessions.append(session_id, "assistant", clarification_question)
        log.info("annotate: unclear query – session %s created", session_id)
        return JSONResponse({
            "session_id": session_id,
            "conversation_id": conversation_id,
            "needs_clarification": True,
            "clarification_question": clarification_question,
            "device_id": device_id,
            "is_new_device": is_new_device,
        })

    # ── Clear query – run pipeline ────────────────────────────────────────────
    session_id = _sessions.create(
        device_id,
        image_bytes,
        query,
        language,
        conversation_id=conversation_id,
    )
    result = await _run_pipeline(
        image_bytes=image_bytes,
        query=query,
        device_id=device_id,
        session_id=session_id,
        conversation_id=conversation_id,
        turn=1,
        language=language,
    )
    result["is_new_device"] = is_new_device
    # Keep session alive for follow-up questions (TTL handles expiry)
    _sessions.append(session_id, "assistant", result.get("explanation", ""))
    return JSONResponse(result)


# ── Clarify request model ─────────────────────────────────────────────────────

class ClarifyRequest(BaseModel):
    session_id: str
    answer: str
    device_id: Optional[str] = None
    conversation_id: Optional[str] = None
    language: Optional[str] = None


@app.post("/transcribe")
async def transcribe_audio(
    audio: UploadFile = File(..., description="Recorded user audio"),
):
    """
    Multilingual ASR endpoint.
    Uses Azure Speech for language detection + transcription.
    Falls back to Gemini if Azure Speech is unavailable.
    """
    audio_bytes = await audio.read()
    log.debug("[transcribe] received audio: size=%d bytes, content_type=%s", len(audio_bytes), audio.content_type)

    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio file.")

    mime_type = audio.content_type or "audio/wav"

    log.info("[transcribe] azure_speech.available=%s", _speech.available)

    if _speech.available:
        log.info("[transcribe] using Azure Speech")
        transcript, language = _speech.transcribe(audio_bytes, mime_type)
    else:
        log.warning("[transcribe] Azure Speech unavailable – falling back to Gemini")
        transcript, language = _gemini.transcribe_audio(audio_bytes, mime_type)

    log.info("[transcribe] result: transcript=%r  language=%s", transcript, language)

    return JSONResponse(
        {
            "transcript": transcript,
            "language": language,
        }
    )


@app.post("/clarify")
async def clarify(req: ClarifyRequest):
    """
    Resume a session after user answers the clarification question.
    Merges conversation history into an enriched query and runs the full pipeline.
    """
    session = _sessions.get(req.session_id)
    if session is None:
        raise HTTPException(
            status_code=404,
            detail="Session not found or expired. Please take a new photo.",
        )

    device_id = req.device_id or session["device_id"]
    conversation_id = req.conversation_id or session.get("conversation_id")
    conversation_id = _supabase.ensure_conversation(device_id, conversation_id)
    session["conversation_id"] = conversation_id
    image_bytes = session["image_bytes"]
    language = req.language or session.get("language", "en-IN")
    history = session["history"]   # [{role, content}, ...]

    # Append user's answer to history
    _sessions.append(req.session_id, "user", req.answer)

    # Build enriched query: original question + clarification answer
    original_query = history[0]["content"]
    enriched_query = f"{original_query} — {req.answer}"
    log.info("clarify: session=%s enriched_query='%s'", req.session_id, enriched_query)

    # prev_query for Neo4j chain
    prev_query_en = _gemini.to_english(original_query)
    turn = sum(1 for h in history if h["role"] == "user") + 1

    result = await _run_pipeline(
        image_bytes=image_bytes,
        query=enriched_query,
        device_id=device_id,
        session_id=req.session_id,
        conversation_id=conversation_id,
        prev_query_en=prev_query_en,
        turn=turn,
        language=language,
    )
    result["is_new_device"] = False
    # Keep session alive for further follow-ups
    _sessions.append(req.session_id, "assistant", result.get("explanation", ""))
    return JSONResponse(result)

@app.get("/conversation/{conversation_id}")
async def get_conversation(conversation_id: str):
    """
    Fetch the complete conversation history from Supabase.
    """
    history = _supabase.get_conversation(conversation_id)
    if not history:
        raise HTTPException(status_code=404, detail="Conversation not found")
    return JSONResponse(history)

@app.get("/history")
async def get_history(device_id: Optional[str] = None):
    """
    Fetch all conversation histories. Optionally filter by device_id.
    """
    history_list = _supabase.list_conversations(device_id)
    return JSONResponse(history_list)

