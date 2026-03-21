#!/usr/bin/env python3
"""
Экспертная агрегация телеметрии: success rate по donor_sni и operator_code.

  python recipe_eval.py [--json] [--min-samples 3]

Читает data/telemetry.jsonl (от ingest_server). Печатает текст или JSON с рекомендацией
порядка donors для следующего catalog (ручное копирование в catalog.json → sign_mesh_config.py).
"""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from dataclasses import dataclass, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOG = ROOT / "data" / "telemetry.jsonl"


@dataclass
class Stats:
    success: int = 0
    block: int = 0
    fail: int = 0

    @property
    def total(self) -> int:
        return self.success + self.block + self.fail

    @property
    def success_rate(self) -> float:
        if self.total == 0:
            return 0.0
        return self.success / self.total


def load_rows():
    if not LOG.is_file():
        return []
    rows = []
    with open(LOG, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def aggregate(rows: list[dict]) -> dict[tuple[str, str], Stats]:
    """Ключ: (operator_code, donor_sni)."""
    out: dict[tuple[str, str], Stats] = defaultdict(Stats)
    for r in rows:
        if r.get("kind") != "tunnel_attempt":
            continue
        op = str(r.get("operator_code") or "unknown")
        donor = str(r.get("donor_sni") or "")
        if not donor:
            continue
        res = r.get("result") or ""
        st = out[(op, donor)]
        if res == "success":
            st.success += 1
        elif res == "blockDetected":
            st.block += 1
        else:
            st.fail += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="print machine-readable summary")
    ap.add_argument("--min-samples", type=int, default=3)
    args = ap.parse_args()

    rows = load_rows()
    agg = aggregate(rows)

    # Глобально по donor (все операторы)
    by_donor: dict[str, Stats] = defaultdict(Stats)
    for (op, donor), st in agg.items():
        ds = by_donor[donor]
        ds.success += st.success
        ds.block += st.block
        ds.fail += st.fail

    ranked = sorted(
        by_donor.items(),
        key=lambda x: (x[1].success_rate, x[1].success, -x[1].block),
        reverse=True,
    )

    report = {
        "telemetry_lines": len(rows),
        "donors_ranked": [
            {
                "donor_sni": d,
                "success_rate": round(s.success_rate, 4),
                "success": s.success,
                "blockDetected": s.block,
                "failure": s.fail,
                "total": s.total,
            }
            for d, s in ranked
            if s.total >= args.min_samples
        ],
        "by_operator": {
            f"{op}|{donor}": asdict(st)
            for (op, donor), st in sorted(agg.items(), key=lambda x: -x[1].total)
            if st.total >= args.min_samples
        },
    }

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return

    print(f"Mycelium recipe_eval — {LOG} ({len(rows)} lines)\n")
    print(f"Donors (min_samples={args.min_samples}):\n")
    for item in report["donors_ranked"]:
        print(
            f"  {item['donor_sni']}: success_rate={item['success_rate']:.2%} "
            f"n={item['total']} (ok={item['success']} dpi={item['blockDetected']} fail={item['failure']})"
        )
    print(
        "\nNext step: отредактируйте donors в catalog.json по этому порядку, "
        "затем python sign_mesh_config.py && curl publish (см. README)."
    )


if __name__ == "__main__":
    main()
