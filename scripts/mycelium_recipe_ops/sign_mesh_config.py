#!/usr/bin/env python3
"""
Подпись внутреннего catalog → внешний envelope (как в Dart MeshCloudSignedBundle).

  # один раз сгенерировать ключ (храните seed в секретнице, не в git):
  python sign_mesh_config.py --generate-key

  # подписать catalog.json → data/published/envelope.json
  python sign_mesh_config.py --catalog catalog.json

Клиент: положите verify key (32 байта = 64 hex) в SecurityConfig.meshCloudConfigEd25519PublicKeyHex
и включите meshCloudConfigAutoApply / gossip по необходимости.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from nacl.signing import SigningKey

ROOT = Path(__file__).resolve().parent
PUBLISHED = ROOT / "data" / "published"
PUBLISHED.mkdir(parents=True, exist_ok=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--generate-key", action="store_true")
    ap.add_argument("--catalog", type=str, default="catalog.json")
    args = ap.parse_args()

    if args.generate_key:
        sk = SigningKey.generate()
        seed = sk.encode().hex()
        pub = sk.verify_key.encode().hex()
        print("MYCELIUM_ED25519_SEED_HEX=" + seed)
        print("CLIENT meshCloudConfigEd25519PublicKeyHex=" + pub)
        return

    seed_hex = os.environ.get("MYCELIUM_ED25519_SEED_HEX", "").strip()
    if not seed_hex:
        raise SystemExit("Set MYCELIUM_ED25519_SEED_HEX (64 hex bytes = 32-byte seed)")
    sk = SigningKey(bytes.fromhex(seed_hex))

    cat_path = Path(args.catalog)
    if not cat_path.is_file():
        raise SystemExit(f"Missing {cat_path}")

    with open(cat_path, encoding="utf-8") as f:
        inner = json.load(f)

    # компактное тело — как ожидает клиент при verify utf8
    body_str = json.dumps(inner, ensure_ascii=False, separators=(",", ":"))
    signed = sk.sign(body_str.encode("utf-8"))
    sig_hex = signed.signature.hex()

    envelope = {"v": 1, "body": body_str, "sig": sig_hex}
    out = PUBLISHED / "envelope.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(envelope, f, ensure_ascii=False, indent=2)
    print("Wrote", out)
    print("Publish: curl -X POST http://127.0.0.1:8787/admin/publish-envelope -H 'Content-Type: application/json' -d @", str(out), sep="")


if __name__ == "__main__":
    main()
