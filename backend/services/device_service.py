import uuid
from typing import Tuple


def _is_valid_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
        return True
    except ValueError:
        return False


class DeviceService:
    """Validates or mints device identifiers, persisting them in Supabase."""

    def __init__(self, supabase_service):
        self._db = supabase_service

    def get_or_create(self, device_id: str | None) -> Tuple[str, bool]:
        """Return *(device_id, is_new_device)*.

        * Valid UUID provided and exists in DB  → return as-is.
        * Valid UUID provided but not in DB     → register it.
        * None or invalid UUID                  → generate a new one.
        """
        if device_id and _is_valid_uuid(device_id):
            if self._db.device_exists(device_id):
                return device_id, False
            self._db.create_device(device_id)
            return device_id, False

        # None or malformed → mint a fresh UUID
        new_id = str(uuid.uuid4())
        self._db.create_device(new_id)
        return new_id, True
