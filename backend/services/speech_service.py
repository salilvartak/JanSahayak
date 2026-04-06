"""
Azure Speech Service – multilingual ASR with automatic language detection.

Uses Azure Cognitive Services Speech SDK.
Supports up to 10 Indian languages via continuous recognition + at-start LID.

Environment variables required:
    AZURE_SPEECH_KEY    – subscription key from Azure portal
    AZURE_SPEECH_REGION – region e.g. "eastus", "centralindia"
"""
from __future__ import annotations

import logging
import os
import tempfile
import threading
from typing import Tuple

log = logging.getLogger(__name__)

# Languages offered to Azure for identification (max 10 for continuous LID)
# Order matters: most-likely first helps with ambiguous short utterances
_CANDIDATE_LANGUAGES = [
    "hi-IN",   # Hindi
    "en-IN",   # English (India)
    "ta-IN",   # Tamil
    "te-IN",   # Telugu
    "bn-IN",   # Bengali
    "mr-IN",   # Marathi
    "gu-IN",   # Gujarati
    "kn-IN",   # Kannada
    "ml-IN",   # Malayalam
    "ur-PK",   # Urdu
]

try:
    import azure.cognitiveservices.speech as speechsdk
    _SDK_OK = True
except ImportError:
    _SDK_OK = False
    log.warning("azure-cognitiveservices-speech not installed – SpeechService unavailable")


class SpeechService:
    """Wraps Azure Speech SDK for multilingual transcription + language detection."""

    def __init__(self) -> None:
        key    = os.getenv("AZURE_SPEECH_KEY", "").strip()
        region = os.getenv("AZURE_SPEECH_REGION", "").strip()

        if not _SDK_OK:
            log.warning("SpeechService: SDK not installed")
            self._available = False
            return

        if not key or not region:
            log.warning("SpeechService: AZURE_SPEECH_KEY / AZURE_SPEECH_REGION not set")
            self._available = False
            return

        self._key    = key
        self._region = region
        self._available = True
        log.info(
            "SpeechService ready  region=%s  key=%s...%s  candidates=%s",
            region,
            key[:6],
            key[-4:],
            _CANDIDATE_LANGUAGES,
        )

    # ── Public ────────────────────────────────────────────────────────────────

    @property
    def available(self) -> bool:
        return self._available

    def transcribe(self, audio_bytes: bytes, mime_type: str = "audio/wav") -> Tuple[str, str]:
        """
        Transcribe *audio_bytes* and detect its language.

        Returns (transcript, bcp47_language_code).
        e.g. ("मुझे पावर बटन दिखाओ", "hi-IN")

        Falls back to ("", "en-IN") on any failure. Never raises.
        """
        if not self._available or not audio_bytes:
            return "", "en-IN"

        tmp_path = None
        try:
            # ── Write audio to temp file ───────────────────────────────────
            suffix = self._suffix(mime_type)
            with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
                tmp.write(audio_bytes)
                tmp_path = tmp.name
            log.debug("transcribe: wrote %d bytes to %s", len(audio_bytes), tmp_path)

            # ── Configure Azure Speech ─────────────────────────────────────
            log.info("transcribe: creating SpeechConfig  region=%s", self._region)
            speech_cfg = speechsdk.SpeechConfig(
                subscription=self._key,
                region=self._region,
            )
            # Reasonable timeouts for short voice commands
            speech_cfg.set_property(
                speechsdk.PropertyId.SpeechServiceConnection_InitialSilenceTimeoutMs,
                "8000",
            )
            speech_cfg.set_property(
                speechsdk.PropertyId.SpeechServiceConnection_EndSilenceTimeoutMs,
                "1500",
            )

            auto_detect_cfg = speechsdk.languageconfig.AutoDetectSourceLanguageConfig(
                languages=_CANDIDATE_LANGUAGES,
            )

            audio_cfg = speechsdk.audio.AudioConfig(filename=tmp_path)

            recognizer = speechsdk.SpeechRecognizer(
                speech_config=speech_cfg,
                audio_config=audio_cfg,
                auto_detect_source_language_config=auto_detect_cfg,
            )

            # ── Continuous recognition (supports all 10 candidates) ────────
            transcript = ""
            language   = "en-IN"
            done       = threading.Event()

            def _on_recognized(evt: speechsdk.SpeechRecognitionEventArgs) -> None:
                nonlocal transcript, language
                if evt.result.reason == speechsdk.ResultReason.RecognizedSpeech:
                    lang_result = speechsdk.AutoDetectSourceLanguageResult(evt.result)
                    transcript += (" " if transcript else "") + evt.result.text.strip()
                    language    = lang_result.language or language
                    log.info("Azure ASR: lang=%s segment='%s'", language, evt.result.text.strip())

            def _on_stopped(evt) -> None:
                done.set()

            recognizer.recognized.connect(_on_recognized)
            recognizer.session_stopped.connect(_on_stopped)
            recognizer.canceled.connect(_on_stopped)

            log.info("transcribe: starting continuous recognition")
            recognizer.start_continuous_recognition_async().get()
            timed_out = not done.wait(timeout=30)   # generous timeout for longer utterances
            recognizer.stop_continuous_recognition_async().get()

            if timed_out:
                log.warning("transcribe: recognition timed out after 30s")
            log.info("transcribe: final='%s' lang=%s", transcript, language)
            return transcript.strip(), language

        except Exception as exc:
            log.exception("transcribe: unexpected error – %s", exc)
            return "", "en-IN"

        finally:
            if tmp_path:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass

    # ── Helpers ───────────────────────────────────────────────────────────────

    @staticmethod
    def _suffix(mime_type: str) -> str:
        mime = mime_type.lower()
        if "wav"  in mime: return ".wav"
        if "mp4"  in mime or "m4a" in mime or "aac" in mime: return ".m4a"
        if "ogg"  in mime: return ".ogg"
        if "webm" in mime: return ".webm"
        if "flac" in mime: return ".flac"
        return ".wav"   # safe default — Azure handles PCM WAV natively
