"""
Vision service – object detection (labels only).

Primary:  YOLOv8-nano  (ultralytics)
Fallback: empty list   (if ultralytics is not installed)

NOTE: No annotated/OpenCV images are produced by this service.
      All visual annotation shown to users is done by Gemini.
"""
from __future__ import annotations

from typing import List

import cv2
import numpy as np

# ── YOLO bootstrap ────────────────────────────────────────────────────────────
try:
    from ultralytics import YOLO as _YOLO

    _model = _YOLO("yolov8n.pt")  # downloaded automatically on first run
    _YOLO_OK = True
except Exception:  # pragma: no cover
    _model = None
    _YOLO_OK = False


# ── Helpers ───────────────────────────────────────────────────────────────────

def _decode(data: bytes):
    arr = np.frombuffer(data, np.uint8)
    return cv2.imdecode(arr, cv2.IMREAD_COLOR)


# ── Service ───────────────────────────────────────────────────────────────────

class VisionService:
    """Detect objects in an image and return a label list (no annotated image)."""

    def detect_labels(self, image_bytes: bytes) -> List[str]:
        """
        Run object detection and return the list of unique detected class names.
        No bounding boxes or annotated images are produced.
        """
        if _YOLO_OK and _model is not None:
            return self._yolo_labels(image_bytes)
        return []

    # ── YOLO path ─────────────────────────────────────────────────────────────

    def _yolo_labels(self, image_bytes: bytes) -> List[str]:
        img = _decode(image_bytes)
        results = _model(img, verbose=False)

        detected: List[str] = []
        for box in results[0].boxes:
            label: str = _model.names[int(box.cls[0])]
            if label not in detected:
                detected.append(label)

        return detected
