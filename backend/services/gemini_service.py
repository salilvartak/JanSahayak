"""
Gemini Vision service

Two capabilities:
  1. highlight_query() – spatial detection: finds ANY described object and draws
                         a bright bounding box on the image (Gemini 2.0 spatial API)
  2. explain()         – generates a 2-3 sentence spoken explanation of the result

SDK: google-genai (new official SDK)
"""
from __future__ import annotations

import io
import json
import logging
import os
import re
from typing import List, Tuple

log = logging.getLogger(__name__)

import PIL.Image
import PIL.ImageOps
import cv2
import numpy as np

try:
    from google import genai
    from google.genai import types as genai_types
    _SDK_OK = True
except ImportError:
    _SDK_OK = False

# ── Constants ─────────────────────────────────────────────────────────────────

# Queries that mean "show everything" — no targeted Gemini detection needed
_GENERIC_QUERIES = {
    '', 'detect all objects', 'detect objects', 'what do you see',
    'describe', 'describe what you see', 'what is in this image',
    'what is this', 'analyse', 'analyze',
    'read this', 'read this out', 'read it', 'read out', 'read',
    'what does it say', 'what does this say', 'what is written',
    'what is written here', 'translate this', 'translate',
}

# Question/filler words stripped when extracting the visual target
_FILLER_WORDS = {
    'where', 'what', 'is', 'are', 'the', 'a', 'an', 'find', 'show', 'me',
    'locate', 'identify', 'highlight', 'point', 'out', 'look', 'for',
    'which', 'can', 'you', 'please', 'there', 'here', 'i', 'want', 'to',
    'see', 'how', 'my', 'this', 'that', 'in', 'on', 'of', 'does',
}

_DETECT_PROMPT = """\
You are a precise visual grounding model. Find: "{query}"

Step 1 — THINK: mentally scan the image and identify the exact physical object \
that best matches the query. Consider shape, colour, size, text labels, and context.

Step 2 — BOX: draw a tight bounding box around ONLY that object.

Grounding rules (critical for accuracy):
• Box the physical object itself, NOT the text/label naming it.
• If the query mentions text as a location hint (e.g. "near the OFF label"), \
  use the text to LOCATE the target, then box the nearby physical control.
• For controls (switches, buttons, knobs, keys, ports): box just the interactive \
  part — not the whole panel or enclosure.
• The box should touch or nearly touch the object's edges on all four sides.
• Never include large amounts of background; a few pixels of margin is fine.
• If the query mentions a product and you see a barcode/QR, box the product \
  packaging, not the barcode.
• Return at most ONE result — the single best match.

Output format — raw JSON array, nothing else:
[{{"label": "short descriptive name", "box_2d": [ymin, xmin, ymax, xmax]}}]

box_2d rules:
• Exactly 4 integers in range 0–1000  (0 = top/left, 1000 = bottom/right)
• ymin < ymax  and  xmin < xmax
• Values are relative to image dimensions (normalised ×1000)

If the object is genuinely not visible in the image, return: []
"""

_REFINE_PROMPT = """\
This is a zoomed-in crop centred on: "{query}"

Your job: return a TIGHTER, more precise box for the object in this crop.

Refinement rules:
• The box edges should align with the visible boundaries of the object.
• Remove excess background — the box should hug the target closely.
• For controls/buttons/switches: box only the interactive element, \
  not the housing or surrounding panel.
• If uncertain, prefer a box that fully contains the object over one \
  that clips it.

Output format — raw JSON array, nothing else:
[{{"label": "short name", "box_2d": [ymin, xmin, ymax, xmax]}}]

box_2d: exactly 4 integers in 0–1000. ymin < ymax, xmin < xmax.
If not visible, return: []
"""

_LANGUAGE_INFO: dict[str, dict[str, str]] = {
    "hi-IN": {"name": "Hindi",    "script": "Devanagari"},
    "mr-IN": {"name": "Marathi",  "script": "Devanagari"},
    "te-IN": {"name": "Telugu",   "script": "Telugu"},
    "ta-IN": {"name": "Tamil",    "script": "Tamil"},
    "bn-IN": {"name": "Bengali",  "script": "Bengali"},
    "gu-IN": {"name": "Gujarati", "script": "Gujarati"},
    "kn-IN": {"name": "Kannada",  "script": "Kannada"},
    "ml-IN": {"name": "Malayalam","script": "Malayalam"},
    "ur-PK": {"name": "Urdu",     "script": "Nastaliq"},
    "en-IN": {"name": "English",  "script": "Latin"},
    "en-US": {"name": "English",  "script": "Latin"},
}

_EXPLAIN_PROMPT = """\
You are speaking out loud to someone who cannot read. Be very short and simple — like a helpful friend.

The person pointed their camera and asked: "{query}"
Highlighted item (if any): {objects}
Language: {language_name} (code: {language}, script: {language_script})

Follow these rules based on what they asked:

IF they want something READ (e.g. "read this", "what does it say", "what is written"):
- Read out the text you see in the image, word by word, simply.
- If no text is visible, say so kindly.

IF they want to FIND something (e.g. "where is the power button"):
- Say what you can see in the photo in one short sentence.
- Then tell them exactly where the highlighted item is using simple directions: "on the left", "at the top", "in the middle", "near the bottom", "on the right side".

IF it is a GENERAL question (e.g. "what is this"):
- Say what the main object in the photo is, simply and clearly.

BARCODE / QR CODE handling:
- If you see a barcode (1D lines) or QR code (square pixel pattern) anywhere in the image, ALWAYS decode it automatically — even if the user did not ask about it.
- Use the decoded number or URL to identify the product (name, brand, category, typical use) and weave that into your answer naturally.
- Example: if you read barcode "8901030865268", tell the user the product name and what it is used for.
- If you cannot fully decode the barcode/QR, mention that the code is partially visible and describe the product from other visual clues on the packaging.
- Do NOT say "barcode" or "QR code" in technical terms. Say something natural like "I can see the product code on this package" and then share the product details.

ALWAYS:
- You MUST write your entire response in {language_name} using {language_script} script. No exceptions.
- If {language_script} is Devanagari, write in Devanagari characters (e.g. यह रिमोट है।).
- If {language_script} is Telugu, write in Telugu characters (e.g. ఇది రిమోట్.).
- If {language_script} is Tamil, write in Tamil characters.
- If {language_script} is Latin and language is English, write in English.
- Use simple everyday words — no technical terms.
- Never say "bounding box", "annotation", "detected", or "image processing".
- Sound warm and natural, not robotic.

Output format (STRICT):
1) Main answer: exactly 2 short natural sentences.
2) Then add exactly 2 follow-up question suggestions the user can ask next.

Return in this exact structure:
<sentence 1>
<sentence 2>
You can also ask:
1) <question suggestion 1?>
2) <question suggestion 2?>

Rules for suggestions:
- They must be relevant to this image/query.
- Keep each suggestion short and easy to speak.
- Keep everything in {language_name} and {language_script}.
"""

# ── Query helpers ─────────────────────────────────────────────────────────────

def _extract_target(query: str) -> str:
    """
    Strip question/filler words to get the core visual object.
    e.g. "Where are the oneplus earphone" → "oneplus earphone"
         "find the caps lock key"         → "caps lock key"
    Falls back to the original query if nothing remains.
    """
    words = query.lower().split()
    filtered = [w for w in words if w not in _FILLER_WORDS]
    return ' '.join(filtered) if filtered else query


# ── Drawing helpers ────────────────────────────────────────────────────────────

def _decode(data: bytes):
    arr = np.frombuffer(data, np.uint8)
    return cv2.imdecode(arr, cv2.IMREAD_COLOR)

def _encode(img) -> bytes:
    _, buf = cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, 92])
    return buf.tobytes()

def _normalise_image_bytes(image_bytes: bytes) -> tuple[PIL.Image.Image, bytes]:
    """
    Normalize orientation/colorspace so model + drawing use identical pixels.
    This prevents shifted boxes when EXIF orientation is present.
    """
    pil = PIL.Image.open(io.BytesIO(image_bytes))
    pil = PIL.ImageOps.exif_transpose(pil).convert("RGB")
    out = io.BytesIO()
    pil.save(out, format="JPEG", quality=95)
    return pil, out.getvalue()

def _draw_targeted_box(img, x1: int, y1: int, x2: int, y2: int, label: str):
    """
    Clean, prominent highlight with no arrows.

    Layers (bottom → top):
      1. Subtle semi-transparent fill
      2. Soft outer glow
      3. Crisp solid border
      4. Corner accents (L-shapes)
      5. Label badge above the box
    """
    COLOR  = (0, 200, 255)   # amber-yellow (BGR) — visible on any background
    BLACK  = (0, 0, 0)
    WHITE  = (255, 255, 255)
    FONT   = cv2.FONT_HERSHEY_SIMPLEX
    h, w   = img.shape[:2]

    # ── 1. Subtle fill (15 % opacity) ────────────────────────────────────────
    overlay = img.copy()
    cv2.rectangle(overlay, (x1, y1), (x2, y2), COLOR, -1)
    cv2.addWeighted(overlay, 0.15, img, 0.85, 0, img)

    # ── 2. Soft outer glow (two blurred passes) ────────────────────────────
    for pad, alpha in ((12, 0.10), (6, 0.25)):
        glow = img.copy()
        cv2.rectangle(glow,
                      (x1 - pad, y1 - pad), (x2 + pad, y2 + pad),
                      COLOR, pad * 2)
        cv2.addWeighted(glow, alpha, img, 1 - alpha, 0, img)

    # ── 3. Crisp solid border ─────────────────────────────────────────────
    cv2.rectangle(img, (x1, y1), (x2, y2), COLOR, 3)

    # ── 4. Corner L-accents (thicker, bright) ────────────────────────────
    ARM = min(30, (x2 - x1) // 4, (y2 - y1) // 4)   # arm length
    THICK_C = 5
    corners = [
        ((x1, y1), ( ARM, 0),   (0,  ARM)),   # top-left
        ((x2, y1), (-ARM, 0),   (0,  ARM)),   # top-right
        ((x1, y2), ( ARM, 0),   (0, -ARM)),   # bottom-left
        ((x2, y2), (-ARM, 0),   (0, -ARM)),   # bottom-right
    ]
    for (cx, cy), (hx, hy), (vx, vy) in corners:
        cv2.line(img, (cx, cy), (cx + hx, cy + hy), WHITE, THICK_C)
        cv2.line(img, (cx, cy), (cx + vx, cy + vy), WHITE, THICK_C)

    # ── 5. Label badge ────────────────────────────────────────────────────
    SCALE, THICK = 0.75, 2
    (tw, th), bl = cv2.getTextSize(label, FONT, SCALE, THICK)
    pad_x, pad_y = 10, 6
    bx1 = x1
    by2 = y1 - 4
    by1 = max(by2 - th - bl - pad_y * 2, 0)
    bx2 = bx1 + tw + pad_x * 2

    # Badge: black background + white text for maximum contrast
    cv2.rectangle(img, (bx1, by1), (bx2, by2), BLACK, -1)
    cv2.rectangle(img, (bx1, by1), (bx2, by2), COLOR, 2)
    cv2.putText(img, label, (bx1 + pad_x, by2 - bl - 2), FONT, SCALE, WHITE, THICK)


# ── Service ───────────────────────────────────────────────────────────────────

_PREFERRED_MODELS = [
    "gemini-2.5-flash",                # latest stable (new accounts)
    "gemini-2.5-pro",                  # more powerful
    "gemini-2.5-flash-preview-04-17",  # preview variant
    "gemini-2.0-flash-001",            # versioned 2.0
    "gemini-2.0-flash",                # base 2.0
    "gemini-1.5-flash",                # legacy fallback
    "gemini-1.5-pro",
]


class GeminiService:

    def __init__(self) -> None:
        api_key = os.getenv("GEMINI_API_KEY", "").strip()
        self._client = None
        self._model: str | None = None

        if not _SDK_OK or not api_key:
            return

        self._client = genai.Client(api_key=api_key)
        self._model = self._pick_model()
        if self._model:
            log.info("GeminiService ready – model: %s", self._model)
        else:
            log.error("GeminiService: no usable model found – check your API key quota")

    def _pick_model(self) -> str | None:
        """List available models, then probe each to find one the account can use."""
        try:
            names = [m.name for m in self._client.models.list()]
            log.info("Available Gemini models: %s", names)
        except Exception as exc:
            log.warning("Could not list models (%s) – will probe defaults", exc)
            names = [f"models/{m}" for m in _PREFERRED_MODELS]

        candidates = [
            c for c in _PREFERRED_MODELS if any(c in n for n in names)
        ] or _PREFERRED_MODELS  # fall back to full list if none matched

        for candidate in candidates:
            try:
                self._client.models.generate_content(
                    model=candidate,
                    contents=["hi"],
                )
                log.info("GeminiService: probed OK – using model: %s", candidate)
                return candidate
            except Exception as exc:
                log.warning("Model %s not usable (%s) – trying next", candidate, exc)

        log.error("GeminiService: no usable model found for this API key")
        return None

    @property
    def available(self) -> bool:
        return self._client is not None and self._model is not None

    def is_generic_query(self, query: str) -> bool:
        return query.lower().strip() in _GENERIC_QUERIES

    # ── 1. Targeted spatial detection ─────────────────────────────────────────

    def _call_detect(self, pil_img, target: str, prompt_template: str = _DETECT_PROMPT) -> list:
        """
        Call Gemini for bounding boxes on *target*.
        Returns a validated list of {label, box_2d} dicts (may be empty).
        Never raises.
        """
        prompt = prompt_template.format(query=target)
        raw = ""
        try:
            response = self._client.models.generate_content(
                model=self._model,
                contents=[prompt, pil_img],
            )
            raw = re.sub(
                r'^```(?:json)?\s*|\s*```$', '',
                response.text.strip(),
                flags=re.MULTILINE,
            ).strip()
            log.info("_call_detect '%s' → %s", target, raw)
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            log.error("_call_detect JSON error – %s | raw='%s'", exc, raw)
            return []
        except Exception as exc:
            log.exception("_call_detect error – %s", exc)
            return []

    def _parse_boxes(self, boxes: list, fallback_label: str, img_w: int, img_h: int):
        """
        Validate and convert Gemini box list to pixel coords.
        Returns list of (x1, y1, x2, y2, label).
        """
        results = []
        for item in boxes:
            label = str(item.get('label', fallback_label))
            box = item.get('box_2d', [])

            # Reject malformed outputs instead of guessing a wrong coordinate layout.
            if len(box) == 5:
                log.warning("  malformed 5-value box_2d %s for '%s' – skipping", box, label)
                continue

            if len(box) != 4:
                log.warning("  malformed box_2d %s for '%s' – skipping", box, label)
                continue

            ymin, xmin, ymax, xmax = [max(0, min(1000, int(v))) for v in box]

            # Gemini sometimes swaps min/max — normalise instead of rejecting
            ymin, ymax = min(ymin, ymax), max(ymin, ymax)
            xmin, xmax = min(xmin, xmax), max(xmin, xmax)

            if ymin >= ymax or xmin >= xmax:
                log.warning("  degenerate box [%d,%d,%d,%d] – skipping", ymin, xmin, ymax, xmax)
                continue

            results.append((
                int(xmin * img_w / 1000),
                int(ymin * img_h / 1000),
                int(xmax * img_w / 1000),
                int(ymax * img_h / 1000),
                label,
            ))
        return results

    def _refine_box(
        self,
        pil_img: PIL.Image.Image,
        fallback_label: str,
        x1: int,
        y1: int,
        x2: int,
        y2: int,
    ) -> tuple[int, int, int, int, str]:
        """
        Run a second pass inside an expanded crop to tighten the initial box.
        Falls back to the original box if refinement fails.
        """
        w, h = pil_img.size
        bw = max(1, x2 - x1)
        bh = max(1, y2 - y1)
        pad_x = max(12, int(bw * 0.20))
        pad_y = max(12, int(bh * 0.20))

        cx1 = max(0, x1 - pad_x)
        cy1 = max(0, y1 - pad_y)
        cx2 = min(w, x2 + pad_x)
        cy2 = min(h, y2 + pad_y)

        if cx2 - cx1 < 8 or cy2 - cy1 < 8:
            return x1, y1, x2, y2, fallback_label

        crop = pil_img.crop((cx1, cy1, cx2, cy2))
        refined = self._call_detect(crop, fallback_label, prompt_template=_REFINE_PROMPT)
        if not refined:
            return x1, y1, x2, y2, fallback_label

        crop_w, crop_h = crop.size
        parsed = self._parse_boxes(refined, fallback_label, crop_w, crop_h)
        if not parsed:
            return x1, y1, x2, y2, fallback_label

        rx1, ry1, rx2, ry2, rlabel = parsed[0]
        fx1, fy1 = cx1 + rx1, cy1 + ry1
        fx2, fy2 = cx1 + rx2, cy1 + ry2
        return fx1, fy1, fx2, fy2, rlabel

    def _consensus_detect(self, pil_img, target: str, n: int = 3) -> list:
        """
        Call Gemini `n` times and pick the most consistent box via IoU voting.
        This dramatically reduces random misplacements.
        """
        all_results = []
        for attempt in range(n):
            boxes = self._call_detect(pil_img, target)
            if boxes:
                all_results.append(boxes[0])  # We only care about the top-1 box

        if not all_results:
            return []
        if len(all_results) == 1:
            return [all_results[0]]

        # Pick the box with the highest average IoU against all others (most agreed-upon)
        best_idx = 0
        best_avg_iou = -1.0
        for i, a in enumerate(all_results):
            iou_sum = 0.0
            for j, b in enumerate(all_results):
                if i == j:
                    continue
                iou_sum += self._box_iou(a.get('box_2d', []), b.get('box_2d', []))
            avg = iou_sum / (len(all_results) - 1)
            if avg > best_avg_iou:
                best_avg_iou = avg
                best_idx = i

        log.info("  consensus: %d/%d results, best IoU=%.2f", len(all_results), n, best_avg_iou)
        return [all_results[best_idx]]

    @staticmethod
    def _box_iou(a: list, b: list) -> float:
        """Compute IoU between two [ymin, xmin, ymax, xmax] boxes (0-1000 scale)."""
        if len(a) != 4 or len(b) != 4:
            return 0.0
        y1 = max(a[0], b[0])
        x1 = max(a[1], b[1])
        y2 = min(a[2], b[2])
        x2 = min(a[3], b[3])
        inter = max(0, y2 - y1) * max(0, x2 - x1)
        area_a = max(0, a[2] - a[0]) * max(0, a[3] - a[1])
        area_b = max(0, b[2] - b[0]) * max(0, b[3] - b[1])
        union = area_a + area_b - inter
        return inter / union if union > 0 else 0.0

    def highlight_query(self, image_bytes: bytes, query: str) -> Tuple[bytes, List[str]]:
        """
        Locate what the user asked for and draw a highlighted box.

        Strategy:
          1. Extract the core visual target from the natural-language query.
          2. Run consensus detection (3 Gemini calls, pick best via IoU).
          3. If empty, retry with the full original query.
          4. Refine the winning box with a crop-based second pass.
          5. Draw clean annotation.

        Returns (annotated_bytes, found_labels).
        On failure or generic query, returns (original_bytes, []).
        """
        if not self.available:
            log.warning("highlight_query: Gemini not available")
            return image_bytes, []

        if query.lower().strip() in _GENERIC_QUERIES:
            log.info("highlight_query: generic query – skipping")
            return image_bytes, []

        target = _extract_target(query)
        log.info("highlight_query: query='%s'  target='%s'", query, target)

        pil_img, aligned_bytes = _normalise_image_bytes(image_bytes)

        # Attempt 1: consensus detection with cleaned target
        boxes = self._consensus_detect(pil_img, target)

        # Attempt 2: full original query (catches cases where brand/context helps)
        if not boxes and target.lower() != query.lower().strip():
            log.info("highlight_query: attempt 2 with full query")
            boxes = self._consensus_detect(pil_img, query)

        if not boxes:
            log.info("highlight_query: not found after 2 attempts")
            return image_bytes, []

        img = _decode(aligned_bytes)
        h, w = img.shape[:2]
        parsed = self._parse_boxes(boxes, target, w, h)

        if not parsed:
            log.warning("highlight_query: all boxes were invalid")
            return image_bytes, []

        found_labels: List[str] = []
        for x1, y1, x2, y2, label in parsed:
            x1, y1, x2, y2, label = self._refine_box(pil_img, label, x1, y1, x2, y2)
            log.info("  drawing box for '%s': (%d,%d)→(%d,%d)", label, x1, y1, x2, y2)
            _draw_targeted_box(img, x1, y1, x2, y2, label)
            if label not in found_labels:
                found_labels.append(label)

        return _encode(img), found_labels

    # ── 2. Spoken explanation ──────────────────────────────────────────────────

    def explain(
        self,
        annotated_image_bytes: bytes,
        query: str,
        detected_objects: List[str],
        language: str = "en-IN",
        rag_context: str = "",
    ) -> str:
        """Return a plain-language explanation. Never raises.

        Args:
            rag_context: Optional Graph RAG context string from Neo4j.
                         Prepended to the prompt so Gemini can use the
                         user's conversation history and environment context.
        """
        if not self.available:
            return self._fallback(detected_objects)

        obj_list = ', '.join(detected_objects) if detected_objects else 'no specific objects'
        lang_info = _LANGUAGE_INFO.get(language, {"name": "English", "script": "Latin"})

        # Build the base prompt via format (rag_context kept separate to avoid
        # curly-brace injection from user-generated content in graph data)
        base_prompt = _EXPLAIN_PROMPT.format(
            query=query,
            objects=obj_list,
            language=language,
            language_name=lang_info["name"],
            language_script=lang_info["script"],
        )

        # Prepend RAG context if available — Gemini sees history BEFORE the task
        if rag_context.strip():
            log.info("[RAG] injecting %d chars of graph context", len(rag_context))
            prompt = rag_context + "\n\n" + base_prompt
        else:
            prompt = base_prompt

        try:
            pil_img = PIL.Image.open(io.BytesIO(annotated_image_bytes))
            response = self._client.models.generate_content(
                model=self._model,
                contents=[prompt, pil_img],
            )
            return response.text.strip()
        except Exception:
            return self._fallback(detected_objects)

    # ── 3. Clarity check ──────────────────────────────────────────────────────

    def check_clarity(self, image_bytes: bytes, query: str) -> tuple[bool, str]:
        """
        Check if the query is clear enough to act on.

        Returns (is_clear, clarification_question).
        If clear or Gemini unavailable → (True, "").
        """
        if not self.available:
            return True, ""

        prompt = (
            f'A person pointed their camera at something and asked: "{query}"\n\n'
            "You can see the image they captured.\n\n"
            "Decide if you can clearly understand what they want:\n"
            "- If YES: respond with exactly: CLEAR\n"
            "- If NO: respond with: UNCLEAR: <one very short question in the "
            "same language as their query>\n\n"
            "Be generous — most queries are clear enough. Only ask if you "
            "genuinely cannot determine what to find or explain.\n"
            "CLEAR examples: 'where is the power button', 'read this', "
            "'find the charger port', 'what is this'\n"
            "UNCLEAR examples: 'show me that', 'find it', 'the thing I need'"
        )

        try:
            pil_img = PIL.Image.open(io.BytesIO(image_bytes))
            response = self._client.models.generate_content(
                model=self._model,
                contents=[prompt, pil_img],
            )
            text = response.text.strip()
            log.info("check_clarity response: %s", text)

            if text.upper().startswith("UNCLEAR:"):
                question = text[len("UNCLEAR:"):].strip()
                return False, question

            return True, ""
        except Exception as exc:
            log.warning("check_clarity failed (%s) – assuming clear", exc)
            return True, ""

    # ── 4. Translate to English (for DB storage) ───────────────────────────────

    def to_english(self, text: str) -> str:
        """
        Translate *text* to English. Returns the original if already English
        or if Gemini is unavailable. Never raises.
        """
        if not self.available or not text.strip():
            return text
        try:
            response = self._client.models.generate_content(
                model=self._model,
                contents=(
                    f"Translate the following to English. "
                    f"If it is already English, return it unchanged. "
                    f"Return ONLY the translated text, nothing else.\n\n{text}"
                ),
            )
            return response.text.strip() or text
        except Exception:
            return text

    def extract_keywords(self, query: str, response: str) -> list[str]:
        """
        Extract core semantic keywords (1-4 words max) representing both the
        user's query and the AI's explanation.
        """
        if not self.available or not query.strip():
            return []
        
        prompt = (
            f"Extract exactly 1 to 4 core topic keywords (nouns/entities) from this interaction.\n"
            f"User asked: '{query}'\n"
            f"AI replied: '{response}'\n\n"
            "Return ONLY a raw JSON array of strings in English format, e.g. [\"laptop\", \"keyboard\"]."
        )
        try:
            res = self._client.models.generate_content(
                model=self._model,
                contents=prompt,
            )
            raw = re.sub(r'^```(?:json)?\s*|\s*```$', '', res.text.strip(), flags=re.MULTILINE).strip()
            keywords = json.loads(raw)
            if isinstance(keywords, list):
                return [str(k).lower().strip() for k in keywords if len(str(k)) > 1]
            return []
        except Exception as exc:
            log.warning("extract_keywords failed: %s", exc)
            return []

    # ── 5. Audio transcription with language detection ─────────────────────────

    def transcribe_audio(self, audio_bytes: bytes, mime_type: str) -> tuple[str, str]:
        """
        Multilingual ASR using Gemini.
        Returns (transcript, language_code_or_name).
        Never raises.
        """
        if not self.available or not audio_bytes:
            return "", "unknown"

        prompt = (
            "You are a multilingual speech transcription engine.\n"
            "Task:\n"
            "1) Detect spoken language from the audio.\n"
            "2) Transcribe exactly what is spoken in the original language.\n\n"
            "Return ONLY compact JSON in this schema:\n"
            '{"language":"<BCP-47 or language name>","transcript":"<verbatim transcription>"}\n'
            "Do not translate. Do not summarize. No markdown."
        )

        raw = ""
        try:
            response = self._client.models.generate_content(
                model=self._model,
                contents=[
                    prompt,
                    genai_types.Part.from_bytes(data=audio_bytes, mime_type=mime_type),
                ],
            )
            raw = response.text.strip()
            raw = re.sub(r'^```(?:json)?\s*|\s*```$', '', raw, flags=re.MULTILINE).strip()
            data = json.loads(raw)
            transcript = str(data.get("transcript", "")).strip()
            language = str(data.get("language", "unknown")).strip() or "unknown"
            return transcript, language
        except Exception as exc:
            log.warning("transcribe_audio failed (%s), raw='%s'", exc, raw)
            return "", "unknown"

    @staticmethod
    def _fallback(detected_objects: List[str]) -> str:
        if not detected_objects:
            return "The image has been processed. No specific objects were detected."
        return f"The image shows: {', '.join(detected_objects)}."
