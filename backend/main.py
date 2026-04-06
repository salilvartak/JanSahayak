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

import asyncio
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


_neo4j_ready = False


async def _neo4j_connect(retries: int = 5, delay: float = 10) -> None:
    global _neo4j_ready
    for attempt in range(1, retries + 1):
        try:
            await _neo4j.verify_connectivity()
            await _neo4j.ensure_indexes()
            _neo4j_ready = True
            log.info("Neo4j connected on attempt %d", attempt)
            return
        except Exception as exc:
            log.warning("Neo4j attempt %d/%d failed: %s", attempt, retries, exc)
            if attempt < retries:
                await asyncio.sleep(delay)
    log.error("Neo4j unavailable after %d attempts — running without graph features", retries)


@app.on_event("startup")
async def _on_startup() -> None:
    asyncio.create_task(_neo4j_connect())


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
    Full annotation pipeline — optimised for speed.
    Target: 3 Gemini calls max (detect, explain, translate-for-DB).
    Returns the JSON response dict.
    """
    unique = str(uuid.uuid4())
    is_english = language in ("en-IN", "en-US")
    query_en = query if is_english else None

    # ── Step 1: Parallel — upload + YOLO + Gemini highlight + translate ───────
    original_path = f"original/{device_id}/{unique}.jpg"

    tasks = [
        asyncio.to_thread(_supabase.upload_image, original_path, image_bytes),  # 0
        asyncio.to_thread(_vision.detect_labels, image_bytes),                   # 1
        asyncio.to_thread(_gemini.highlight_query, image_bytes, query),          # 2
    ]
    if not is_english:
        tasks.append(asyncio.to_thread(_gemini.to_english, query))               # 3

    results = await asyncio.gather(*tasks, return_exceptions=True)

    if isinstance(results[0], Exception):
        raise HTTPException(status_code=502, detail=f"Supabase upload failed: {results[0]}")
    if isinstance(results[1], Exception):
        raise HTTPException(status_code=500, detail=f"Vision service failed: {results[1]}")

    original_url: str = results[0]
    yolo_labels: list = results[1]
    gemini_annotated, gemini_labels = results[2] if not isinstance(results[2], Exception) else (image_bytes, [])
    if not is_english:
        query_en = results[3] if not isinstance(results[3], Exception) else query
        log.info("[pipeline] translated query: %r → %r", query, query_en)

    annotated_bytes = gemini_annotated if gemini_labels else image_bytes
    detected_objects = list(dict.fromkeys(yolo_labels + gemini_labels))

    # ── Step 2: Parallel — upload annotated + RAG context + explanation ───────
    annotated_path = f"annotated/{device_id}/{unique}.jpg"

    step2 = await asyncio.gather(
        asyncio.to_thread(_supabase.upload_image, annotated_path, annotated_bytes),
        _neo4j.get_rag_context(device_id=device_id, session_id=session_id, current_objects=detected_objects),
        return_exceptions=True,
    )

    if isinstance(step2[0], Exception):
        raise HTTPException(status_code=502, detail=f"Supabase upload failed: {step2[0]}")

    annotated_url: str = step2[0]
    rag_context: str = step2[1] if not isinstance(step2[1], Exception) else ""

    # ── Step 3: Gemini explanation (needs RAG context from step 2) ────────────
    explanation = await asyncio.to_thread(
        _gemini.explain,
        image_bytes,
        query,
        detected_objects,
        language,
        rag_context,
    )

    # ── Fire-and-forget — DB writes after response is ready ──────────────────
    async def _post_process():
        try:
            qid = await asyncio.to_thread(
                _supabase.create_query,
                device_id, query, conversation_id, explanation,
            )
            if turn == 1:
                await asyncio.to_thread(_supabase.touch_conversation, conversation_id, query)
            else:
                await asyncio.to_thread(_supabase.touch_conversation, conversation_id)
            await asyncio.to_thread(
                _supabase.create_image_record, device_id, qid, original_url, annotated_url
            )
            explanation_en = explanation if is_english else await asyncio.to_thread(_gemini.to_english, explanation)
            keywords = await asyncio.to_thread(_gemini.extract_keywords, query_en or query, explanation_en)
            await _neo4j.record_interaction(
                device_id=device_id, query_id=qid, query_text=query_en or query,
                response_text=explanation_en, image_url=original_url,
                keywords=keywords, session_id=session_id,
                prev_query_text=prev_query_en, turn=turn,
            )
        except Exception as exc:
            log.error("[post_process] error: %s", exc, exc_info=True)

    asyncio.create_task(_post_process())

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

    # Skip clarity check — run pipeline directly for speed
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
    # Cache pipeline outputs in the session so /clarify can skip re-detection
    session = _sessions.get(session_id)
    if session:
        session["detected_objects"] = result.get("detected_objects", [])
        session["annotated_url"] = result.get("annotated_url", "")
        session["original_url"] = result.get("original_url", "")
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
    Follow-up endpoint.  Uses the existing session image + conversation history
    to answer the user's new question *without* re-running the full detection
    pipeline.  Only calls Gemini once (explain) → much faster.
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

    _sessions.append(req.session_id, "user", req.answer)

    turn = sum(1 for h in history if h["role"] == "user") + 1
    original_query = history[0]["content"]
    follow_up_query = req.answer

    log.info("clarify: session=%s turn=%d follow_up='%s'", req.session_id, turn, follow_up_query)

    is_english = language in ("en-IN", "en-US")

    # Build conversation context for Gemini
    convo_lines = []
    for h in history:
        role_label = "User" if h["role"] == "user" else "Assistant"
        convo_lines.append(f"{role_label}: {h['content']}")
    convo_context = "\n".join(convo_lines)

    # Reuse previously detected objects & annotated image from session
    detected_objects = session.get("detected_objects", [])
    annotated_url = session.get("annotated_url", "")
    original_url = session.get("original_url", "")

    # Fetch RAG context in parallel with optional translation
    rag_task = _neo4j.get_rag_context(
        device_id=device_id, session_id=req.session_id,
        current_objects=detected_objects,
    )
    translate_task = (
        asyncio.to_thread(_gemini.to_english, follow_up_query)
        if not is_english else None
    )

    tasks_results = await asyncio.gather(
        rag_task,
        translate_task or asyncio.sleep(0),
        return_exceptions=True,
    )

    rag_context = tasks_results[0] if not isinstance(tasks_results[0], Exception) else ""
    query_en = follow_up_query if is_english else (
        tasks_results[1] if not isinstance(tasks_results[1], Exception) else follow_up_query
    )

    # Single Gemini call: explain with full conversation context
    explanation = await asyncio.to_thread(
        _gemini.explain_followup,
        image_bytes,
        follow_up_query,
        detected_objects,
        language,
        rag_context,
        convo_context,
    )

    # Fire-and-forget DB writes
    async def _post_process():
        try:
            qid = await asyncio.to_thread(
                _supabase.create_query,
                device_id, follow_up_query, conversation_id, explanation,
            )
            await asyncio.to_thread(_supabase.touch_conversation, conversation_id)
            explanation_en = explanation if is_english else await asyncio.to_thread(_gemini.to_english, explanation)
            keywords = await asyncio.to_thread(_gemini.extract_keywords, query_en, explanation_en)
            await _neo4j.record_interaction(
                device_id=device_id, query_id=qid, query_text=query_en,
                response_text=explanation_en, image_url=original_url,
                keywords=keywords, session_id=req.session_id,
                prev_query_text=original_query, turn=turn,
            )
        except Exception as exc:
            log.error("[clarify post_process] error: %s", exc, exc_info=True)

    asyncio.create_task(_post_process())

    result = {
        "session_id": req.session_id,
        "conversation_id": conversation_id,
        "needs_clarification": False,
        "clarification_question": "",
        "device_id": device_id,
        "query_id": str(uuid.uuid4()),
        "image_id": str(uuid.uuid4()),
        "original_url": original_url,
        "annotated_url": annotated_url,
        "detected_objects": detected_objects,
        "annotated_image_base64": "",
        "explanation": explanation,
        "is_new_device": False,
    }
    _sessions.append(req.session_id, "assistant", explanation)
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

