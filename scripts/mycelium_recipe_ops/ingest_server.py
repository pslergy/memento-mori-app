#!/usr/bin/env python3
"""
Mycelium ingest + отдача последнего подписанного MESH_CLOUD_CONFIG.

Запуск:
  export MYCELIUM_HMAC_SECRET_HEX=...   # опционально, общий с SecurityConfig.myceliumTelemetryHmacSecretHex
  export MYCELIUM_ADMIN_TOKEN=...       # опционально, Bearer для POST /admin/publish
  uvicorn ingest_server:app --host 0.0.0.0 --port 8787

Проксируйте с VPS на путь под вашим API, например /api/dpi/...
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
DATA.mkdir(exist_ok=True)
TELEMETRY_LOG = DATA / "telemetry.jsonl"
PUBLISHED_DIR = DATA / "published"
PUBLISHED_DIR.mkdir(exist_ok=True)
LATEST_ENVELOPE = PUBLISHED_DIR / "envelope.json"

app = FastAPI(title="Mycelium recipe ops", version="1")


def _hmac_secret() -> bytes | None:
    hx = os.environ.get("MYCELIUM_HMAC_SECRET_HEX", "").strip()
    if not hx or len(hx) % 2:
        return None
    return bytes.fromhex(hx)


def _verify_hmac(body: bytes, header: str | None) -> None:
    secret = _hmac_secret()
    if secret is None:
        return
    if not header:
        raise HTTPException(401, "missing X-Mycelium-Hmac")
    try:
        got = bytes.fromhex(header.strip())
    except ValueError:
        raise HTTPException(401, "bad HMAC hex")
    expected = hmac.new(secret, body, hashlib.sha256).digest()
    if not hmac.compare_digest(got, expected):
        raise HTTPException(403, "bad HMAC")


@app.post("/dpi/mycelium-telemetry")
async def ingest_telemetry(request: Request, x_mycelium_hmac: str | None = Header(default=None)):
    body = await request.body()
    _verify_hmac(body, x_mycelium_hmac)
    try:
        rec = json.loads(body.decode("utf-8"))
    except json.JSONDecodeError:
        raise HTTPException(400, "invalid json")
    if rec.get("v") != 1:
        raise HTTPException(400, "unsupported v")
    line = json.dumps(rec, ensure_ascii=False) + "\n"
    with open(TELEMETRY_LOG, "a", encoding="utf-8") as f:
        f.write(line)
    return {"ok": True}


@app.get("/dpi/mesh-cloud-config/latest")
def get_latest_envelope():
    if not LATEST_ENVELOPE.is_file():
        return JSONResponse({"ok": False, "error": "no envelope"}, status_code=404)
    with open(LATEST_ENVELOPE, encoding="utf-8") as f:
        env = json.load(f)
    return {"ok": True, "envelope": env}


@app.post("/admin/publish-envelope")
async def publish_envelope(request: Request, authorization: str | None = Header(default=None)):
    token = os.environ.get("MYCELIUM_ADMIN_TOKEN", "").strip()
    if not token:
        raise HTTPException(
            503, "MYCELIUM_ADMIN_TOKEN must be set — refusing unsigned admin publish"
        )
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Bearer required")
    if authorization[7:].strip() != token:
        raise HTTPException(403, "bad token")
    body = await request.body()
    try:
        env = json.loads(body.decode("utf-8"))
    except json.JSONDecodeError:
        raise HTTPException(400, "invalid json")
    if env.get("v") != 1 or "body" not in env or "sig" not in env:
        raise HTTPException(400, "expected v=1 envelope with body and sig")
    with open(LATEST_ENVELOPE, "w", encoding="utf-8") as f:
        json.dump(env, f, ensure_ascii=False, indent=2)
    return {"ok": True, "path": str(LATEST_ENVELOPE)}


@app.get("/health")
def health():
    return {"ok": True, "ts": datetime.now(timezone.utc).isoformat()}
