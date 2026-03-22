<div align="center">

# 💀 Memento Mori

### Resilient offline-first mesh infrastructure

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://flutter.dev)
[![Status](https://img.shields.io/badge/Status-Research%20Alpha-orange.svg)]()
[![Website](https://img.shields.io/badge/Website-GitHub%20Pages-blue.svg)](https://pslergy.github.io/memento-mori-app/)

**Autonomous decentralized communication for constrained networks**  
*Delay-tolerant • Mesh-first • Air-gap–friendly scenarios*

<br>

<!-- Add screenshots under assets/screenshots/ for the gallery below -->
<img src="assets/screenshots/1.jpg" width="220" alt="Radar UI" />
<img src="assets/screenshots/2.jpg" width="220" alt="Chat UI" />
<img src="assets/screenshots/3.jpg" width="220" alt="Mesh settings" />
<img src="assets/screenshots/4.jpg" width="220" alt="Mesh settings" />
<img src="assets/screenshots/5.jpg" width="220" alt="Mesh settings" />

</div>

---

## ⚠️ Research preview — not a production release

Independent research into **delay-tolerant** and **ad hoc** mobile networking. Code is published for **education and peer review**. The mesh path can operate **without relying on a single central messaging plane**; optional cloud features may still be used when available.

---

## 🧠 Core research areas

### 1. Hardware-aware transport

Coping with vendor power limits, flaky radio, and Android BLE quirks (background limits, `GATT_BUSY`, fragmentation).

### 2. Hybrid transport stack

| Layer | Role |
|-------|------|
| **BLE** | Discovery, control, store-and-forward messaging |
| **Wi‑Fi Direct** | On-demand higher throughput where supported |
| **Acoustic (experimental)** | Close-range exchange without BLE/Wi‑Fi |

### 3. Distributed consistency

Store-and-forward queues, **epidemic-style** relay with TTL/dedup, **CRDT-oriented** sync for partitioned histories.

### 4. Local data protection

Dual-context storage (e.g. REAL / decoy paths), selective key handling, offline-oriented identity material. See [**SECURITY.md**](SECURITY.md) for limits and threat model.

### 5. Resilience & obfuscation

Transport diversity, optional **DPI-oriented** channel selection, **hop-count–based** uplink heuristics (GHOST/BRIDGE roles). *Not* a full continuous “gradient field” router — see status table below.

---

## 📊 Current Status

| Component | Status | Notes |
|-----------|--------|-------|
| BLE discovery & messaging | ✅ Working | Tested on multiple vendors |
| CRDT-based history sync | ✅ Working | |
| Store-and-forward outbox | ✅ Working | |
| Wi-Fi Direct transport | ✅ Working | |
| Acoustic channel | ✅ Working | Experimental |
| DPI-aware transport selection | ✅ Working | |
| Double Ratchet E2EE | ✅ Working | Optional mode |
| Gradient-based routing | 🧪 Testing | |
| LoRa WAN integration | 📋 Planned | |

---

## 🛠 Tech stack

| Area | Stack |
|------|--------|
| App | **Dart** (Flutter), **Kotlin** (platform channels) |
| DI / state | **get_it**, **Provider** (not BLoC in the main app) |
| Local DB | **SQLite** via **sqflite** |
| Crypto | **`cryptography`**, **`crypto`** (see SECURITY.md — not a Signal clone) |
| DSP | Goertzel / FFT utilities where used for acoustic experiments |

---

## 📥 Getting started

### Prerequisites

- Flutter SDK **3.x** (`>=3.1.0` per `pubspec.yaml`)
- **Android** device (API 26+ recommended)
- **Physical devices** for meaningful mesh / BLE tests (emulator coverage is limited)


---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [**ARCHITECTURE.md**](ARCHITECTURE.md) | System design & transport layers |
| [**WHY_NOT_SIGNAL.md**](WHY_NOT_SIGNAL.md) | Design rationale vs Signal-class messengers |
| [**SECURITY.md**](SECURITY.md) | Threat model & cryptography (high level) |
| [**docs/E2EE_PRIORITIES.md**](docs/E2EE_PRIORITIES.md) | E2EE roadmap / deferred server pre-keys |
| [**docs/E2EE_USER_FAQ_RU.md**](docs/E2EE_USER_FAQ_RU.md) | User-oriented FAQ (Russian) |

---



---

## 🤝 Contributing

Research welcome in transport behavior, crypto review, and DSP. Please read [**CONTRIBUTING.md**](CONTRIBUTING.md) before opening issues or PRs.

---

## 📄 License

**GNU General Public License v3.0** — see [LICENSE](LICENSE).

---

<div align="center">

**Memento Mori** — *memento mori*: systems should survive disconnections.

*Independent research project.*

</div>
