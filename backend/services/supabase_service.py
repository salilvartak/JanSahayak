import logging
import os
import uuid
from datetime import datetime, timezone
from supabase import create_client, Client

log = logging.getLogger(__name__)

BUCKET = "images"


class SupabaseService:
    """Handles all Supabase storage + database operations."""

    def __init__(self) -> None:
        url = os.getenv("SUPABASE_URL", "").strip()
        key = os.getenv("SUPABASE_SERVICE_KEY", "").strip()
        if not url or not key:
            raise RuntimeError(
                "SUPABASE_URL and SUPABASE_SERVICE_KEY must be set in the environment."
            )
        self.client: Client = create_client(url, key)
        self._base_url = url.rstrip("/")

    # ── Devices ──────────────────────────────────────────────────────────────

    def device_exists(self, device_id: str) -> bool:
        res = self.client.table("devices").select("id").eq("id", device_id).execute()
        return len(res.data) > 0

    def create_device(self, device_id: str) -> str:
        self.client.table("devices").insert({"id": device_id}).execute()
        return device_id

    # ── Conversations ─────────────────────────────────────────────────────────

    def ensure_conversation(self, device_id: str, conversation_id: str | None = None) -> str:
        """
        Ensure a conversation row exists and belongs to *device_id*.
        Returns the usable conversation_id.
        """
        if conversation_id:
            res = (
                self.client.table("conversations")
                .select("id, device_id")
                .eq("id", conversation_id)
                .limit(1)
                .execute()
            )
            if res.data:
                if res.data[0]["device_id"] == device_id:
                    return conversation_id
                log.warning(
                    "conversation %s belongs to a different device; creating new conversation",
                    conversation_id,
                )
            else:
                self.client.table("conversations").insert(
                    {"id": conversation_id, "device_id": device_id}
                ).execute()
                return conversation_id

        new_conversation_id = str(uuid.uuid4())
        self.client.table("conversations").insert(
            {"id": new_conversation_id, "device_id": device_id}
        ).execute()
        return new_conversation_id

    def touch_conversation(self, conversation_id: str, title: str | None = None) -> None:
        payload = {"updated_at": datetime.now(timezone.utc).isoformat()}
        if title:
            payload["title"] = title.strip()[:120]
        (
            self.client.table("conversations")
            .update(payload)
            .eq("id", conversation_id)
            .execute()
        )

    # ── Queries ───────────────────────────────────────────────────────────────

    def create_query(
        self, device_id: str, query_text: str, conversation_id: str | None = None, response_text: str | None = None
    ) -> str:
        query_id = str(uuid.uuid4())
        payload = {"id": query_id, "device_id": device_id, "query_text": query_text}
        if conversation_id:
            payload["conversation_id"] = conversation_id
        if response_text:
            payload["response_text"] = response_text
        self.client.table("queries").insert(payload).execute()
        return query_id
        
    def get_conversation(self, conversation_id: str) -> dict | None:
        c_res = self.client.table("conversations").select("*").eq("id", conversation_id).execute()
        if not c_res.data:
            return None
        c_data = c_res.data[0]
        
        q_res = self.client.table("queries").select("*").eq("conversation_id", conversation_id).order("created_at").execute()
        queries = q_res.data
        
        # Get the latest image for preview
        i_res = (self.client.table("images")
            .select("annotated_image_url")
            .in_("query_id", [q["id"] for q in queries])
            .order("created_at", desc=True)
            .limit(1)
            .execute())
            
        preview_url = i_res.data[0]["annotated_image_url"] if i_res.data else ""
        
        turns = []
        for q in queries:
            turns.append({
                "role": "user",
                "text": q["query_text"],
                "created_at": q["created_at"]
            })
            if q.get("response_text"):
                turns.append({
                    "role": "assistant",
                    "text": q["response_text"],
                    "created_at": q["created_at"] # use query timestamp approx
                })
                
        return {
            "id": c_data["id"],
            "session_id": "", # we don't persist it, so blank
            "device_id": c_data["device_id"],
            "preview_image_url": preview_url,
            "created_at": c_data["created_at"],
            "updated_at": c_data["updated_at"],
            "turns": turns
        }

    def list_conversations(self, device_id: str | None = None) -> list[dict]:
        query = self.client.table("conversations").select("*").order("updated_at", desc=True)
        if device_id:
            query = query.eq("device_id", device_id)
        
        c_res = query.execute()
        if not c_res.data:
            return []
            
        conversations = c_res.data
        conv_ids = [c["id"] for c in conversations]
        
        if not conv_ids:
            return []
            
        q_res = self.client.table("queries").select("*").in_("conversation_id", conv_ids).order("created_at").execute()
        queries = q_res.data
        
        query_ids = [q["id"] for q in queries]
        images_dict = {}
        if query_ids:
            i_res = (self.client.table("images")
                .select("query_id, annotated_image_url")
                .in_("query_id", query_ids)
                .order("created_at", desc=True)
                .execute())
            for img in i_res.data:
                if img["query_id"] not in images_dict:
                    images_dict[img["query_id"]] = img["annotated_image_url"]
                    
        from collections import defaultdict
        queries_by_conv = defaultdict(list)
        for q in queries:
            queries_by_conv[q["conversation_id"]].append(q)
            
        result = []
        for c in conversations:
            c_queries = queries_by_conv[c["id"]]
            
            preview_url = ""
            for q in reversed(c_queries):
                if q["id"] in images_dict:
                    preview_url = images_dict[q["id"]]
                    break
            
            turns = []
            for q in c_queries:
                turns.append({
                    "role": "user",
                    "text": q["query_text"],
                    "created_at": q["created_at"]
                })
                if q.get("response_text"):
                    turns.append({
                        "role": "assistant",
                        "text": q["response_text"],
                        "created_at": q["created_at"]
                    })
                    
            result.append({
                "id": c["id"],
                "session_id": "", 
                "device_id": c["device_id"],
                "preview_image_url": preview_url,
                "created_at": c["created_at"],
                "updated_at": c["updated_at"],
                "turns": turns
            })
            
        return result

    # ── Images ────────────────────────────────────────────────────────────────

    def create_image_record(
        self,
        device_id: str,
        query_id: str,
        original_url: str,
        annotated_url: str,
    ) -> str:
        image_id = str(uuid.uuid4())
        self.client.table("images").insert(
            {
                "id": image_id,
                "device_id": device_id,
                "query_id": query_id,
                "original_image_url": original_url,
                "annotated_image_url": annotated_url,
            }
        ).execute()
        return image_id

    # ── Storage ───────────────────────────────────────────────────────────────

    def upload_image(self, path: str, data: bytes) -> str:
        """Upload *data* to the *images* bucket at *path*, return public URL."""
        try:
            self.client.storage.from_(BUCKET).upload(
                path=path,
                file=data,
                file_options={"content-type": "image/jpeg"},
            )
        except Exception as exc:
            log.exception("upload_image failed for path=%s: %s", path, exc)
            raise
        return f"{self._base_url}/storage/v1/object/public/{BUCKET}/{path}"
