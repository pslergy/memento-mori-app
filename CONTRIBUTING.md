# Contributing to Memento Mori

Thank you for your interest in **Memento Mori**.

This is an **independent research** project: resilient, **offline-first** mesh communication and optional cloud paths. We prioritize **security awareness**, **honest threat modeling**, and **changes that survive real Android hardware**.

---

## Before you start

1. Read [**SECURITY.md**](SECURITY.md) (reporting vulnerabilities **only** via private channels — not public issues).
2. Skim [**ARCHITECTURE.md**](ARCHITECTURE.md) for system design and transport layers.
3. This repository contains the **reference messenger app** — say in your issue/PR which area you touch.

---

## Areas we care about

### Acoustic / ultrasonic experiments

- Symbol timing, clock drift, detection robustness (e.g. Goertzel / FFT paths).
- CPU and battery cost on low-end devices.
- Behavior in noise and multipath.

### Security & cryptography

- Reviews of **concrete** flows (e.g. DM encryption, Double Ratchet phases, wire formats).
- Threat-model notes aligned with [**SECURITY.md**](SECURITY.md) — not marketing claims.
- **Do not** open public issues for unfixed vulnerabilities.

### Android transport & OEM reality

- BLE reliability, foreground services, vendor power managers (Xiaomi, Huawei, etc.).
- Wi‑Fi Direct edge cases, audio/BLE coexistence.
- **Physical devices** strongly preferred for anything touching radio.

### MeshStack SDK

- Pack isolation, public API clarity, reproducible examples.
- SDK-related changes should reference the corresponding examples.

---

## Development workflow

### Branches

| Pattern | Use |
|---------|-----|
| `main` | Integration target; keep history reviewable |
| `feature/<topic>` | Features, refactors |
| `fix/<topic>` | Bugfixes, regressions |

Fork → branch → PR is fine. Avoid huge “kitchen sink” PRs.

### Pull requests

- **One logical change** per PR when possible; commits should be **easy to bisect**.
- **No secrets**: API keys, tokens, production URLs, or key material in code or docs.
- **Docs**: update README / `docs/` / design `.md` when behavior or guarantees change.
- **Tests**: run `flutter test` (and targeted tests under `test/`) for Dart changes.
- **Mesh / BLE / audio**: state **device models + Android version** in the PR description when you validated on hardware.

### Code style (Dart / Flutter)

- Enable and follow **`flutter_lints`** (see `analysis_options.yaml`).
- Main app uses **get_it** (locator) and **Provider** in places — prefer **explicit** lifecycle and avoid hidden globals.
- Prefer **clear naming** and **short comments** where protocols or OEM quirks are non-obvious.

### Kotlin / Android (platform channels)

- Respect **bounded** concurrency; no unbounded background work.
- Document **permissions** and **OEM-specific** assumptions in code comments when relevant.

---

## What we are unlikely to merge

- **Undisclosed** telemetry, analytics, or behavioral tracking in core paths.
- **Opaque** cloud dependencies for **core** mesh operation without a strong, documented rationale.
- Changes that **break GPL v3** obligations or ship proprietary blobs without clear licensing.

We are **not** aiming to clone WhatsApp/Signal; see [**WHY_NOT_SIGNAL.md**](WHY_NOT_SIGNAL.md).

---

## Issues

- Use **clear reproduction steps** for bugs (app version, OS, transport used).
- Prefix or label when possible: `mesh`, `ble`, `crypto`, `sdk`, `docs`, `android`.
- **Questions** welcome if they reference files or behavior (e.g. “MessageRouter.resolvePath + BRIDGE”).

---

## License

By contributing, you agree that your contributions are licensed under the **same license as the project** — [**GNU GPL v3**](LICENSE), unless explicitly stated otherwise for a given subdirectory that carries its own `LICENSE`.

---

*Memento Mori — protocol design for when connectivity is not guaranteed.*
