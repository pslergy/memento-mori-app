<div align="center">

# Memento Mori
Independent research project exploring resilient mobile mesh networking under OS-level constraints.

### Autonomous Shadow Mesh Infrastructure

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Open Source](https://img.shields.io/badge/Open%20Source-Yes-success.svg)]()
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://flutter.dev)
[![Status](https://img.shields.io/badge/Status-Research%20Alpha-orange.svg)]()
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-GitHub-pink.svg)](https://github.com/sponsors/pslergy)

**Resilient Decentralized Communication for Extreme Environments**

<p align="center">
  <!-- PLACEHOLDER FOR DEMO GIF OR SCREENSHOT -->
  <!-- <img src="assets/screenshots/radar_demo.gif" width="300" alt="Sonar Radar Demo" /> -->
  <i>(Visual demonstration coming soon)</i>
</p>

</div>

---

> ⚠️ **RESEARCH PREVIEW (ALPHA)**
>
> **Memento Mori is currently under active engineering development.**
> The protocol implementation, database schema, and routing logic may undergo breaking changes.
> This software is designed for research and testing of **Delay-Tolerant Networks (DTN)** and is **not recommended for mission-critical use** without prior validation.

---

## 💀 The Mission

**Memento Mori** is a fault-tolerant, autonomous mesh infrastructure designed to operate under **total network degradation**.

The project implements a **shadow communication layer** beneath the traditional Internet, leveraging a combination of acoustic signaling, radio-based discovery, and cloud gateways when available. It is built for environments where connectivity is intermittent, hostile, monitored, or deliberately suppressed.

---

## 🧠 Core Engineering Innovation

### 1. Tactical Orchestrator (Decision Engine)

The primary challenge of mobile mesh networks is **surviving the operating system**.
Aggressive power management (Doze mode) and shared hardware resources (Bluetooth, Audio, Wi-Fi) often terminate background mesh processes.

Memento Mori solves this via a deterministic **Hardware Interlock**:

* **Anti-Deadlock Logic:** Enforces exclusive HAL access to prevent Bluetooth GATT status 133 errors.
* **Biological Burst-Mode:** Nodes synchronize wake cycles to exchange data in short, high-throughput bursts, saving up to **90% battery**.
* **Crash Guard:** Prevents audio driver starvation during Sonar operations on specific chipsets (MediaTek / Spreadtrum).

---

### 2. Multi-Layer Hybrid Transport

The app dynamically switches transport layers based on tactical conditions:

* **🦇 Acoustic Sonar (L2):**
  Air-gapped discovery using ultrasonic BFSK modulation (18–20 kHz).
  Works in radio silence or RF-monitored zones using the Goertzel algorithm on the CPU.

* **📡 BLE Control Plane:**
  Zero-connect topology inference. Nodes broadcast gradient state (hop counts) directly in advertising packets without establishing heavy connections.

* **⚡ Wi-Fi Direct (Data Plane):**
  Automatic escalation. When a BLE link is verified, a high-bandwidth Wi-Fi group is formed to flush the message queue instantly.

---

### 3. Identity Transmigration

* **Ghost State:** Fully functional offline identity (Ed25519) stored in SQLite (WAL mode).
* **Atomic Merge:** When internet access becomes available, the offline ghost identity is cryptographically bound to a persistent ID without history loss or forks.

---

## 🗺️ Roadmap & Status

* [x] **Core:** BLE zero-connect discovery & advertising parsing
* [x] **Core:** Hardware interlock (GATT / Sonar conflict resolution)
* [x] **Transport:** Acoustic sonar layer (BFSK signaling)
* [x] **Transport:** Wi-Fi Direct auto-negotiation
* [x] **Security:** Ghost identity & local encryption (SQLite WAL)
* [x] **UI:** Basic radar interface and chat view
* [ ] **Routing:** Stabilize gradient descent (multi-hop reliability)
* [ ] **Security:** Double Ratchet algorithm (E2EE)
* [ ] **Network:** LoRa WAN hardware integration (USB / UART)
* [ ] **UI:** Camouflage mode (calculator disguise)

---

## 🐛 Known Issues

* **Huawei / Xiaomi:** Aggressive battery optimization may kill background service after 10–15 minutes.
  *Workaround: manual whitelist required.*

* **Audio Audibility:** In very quiet rooms, ultrasonic handshake (~17.5 kHz) may be faintly audible to young people or pets.

* **Wi-Fi Direct:** Android 9 and below may experience slow group negotiation.

---

## 🛠 Tech Stack

* **Language:** Dart (Flutter) + Kotlin (native channels)
* **Architecture:** Clean Architecture + BLoC
* **Database:** SQLite (FFI, WAL mode)
* **Crypto:** pointycastle / cryptography (Ed25519, AES-GCM)

---

## 📥 Getting Started

### Prerequisites

* Flutter SDK 3.x+
* Android device (API 26+ recommended)
  *Emulators are limited due to Bluetooth and Wi-Fi Direct requirements.*

### Installation

```bash
git clone https://github.com/pslergy/memento-mori-app.git
cd memento-mori-app
flutter pub get
flutter run --release
```

---

## ❤️ Support the Project

**Memento Mori** is an independent open-source research project developed without corporate backing.

If you find this work valuable and want to support:

* long-term research into resilient offline communication
* maintenance across diverse Android hardware
* documentation, testing, and security audits

You can support the project via **GitHub Sponsors**:

👉 [https://github.com/sponsors/pslergy](https://github.com/sponsors/pslergy)

Every contribution helps keep the project sustainable and open.

---

## 📚 Project Documentation

This repository is accompanied by a set of architectural and design documents
that explain *why* Memento Mori exists and *how* it differs from conventional messengers.

* **🧭 Architecture Overview**
  → [`ARCHITECTURE.md`](ARCHITECTURE.md)
  High-level system design, transport layers, orchestrator logic, and data flow.

* **❓ Why this is not Signal or Matrix**
  → [`WHY_NOT_SIGNAL_OR_MATRIX.md`](WHY_NOT_SIGNAL_OR_MATRIX.md)
  Explicit comparison of assumptions, threat models, and architectural goals.

* **🛡 Threat Model (coming soon)**
  Offline-first security assumptions, adversarial environments, and OS hostility.

These documents are considered part of the project specification.
Core changes should remain consistent with them.

---


### 🤝 Contributing

This is an open research project. Contributions are welcome, especially in:

* DSP / audio signal processing (Goertzel optimization)
* Android HAL quirks (Samsung, Pixel, Xiaomi)
* Cryptographic review and security testing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening issues or pull requests.


---

## 📄 License

Licensed under the **GNU General Public License v3.0**.
See the [LICENSE](LICENSE) file for details.

> **Disclaimer:** Provided as-is for educational and defensive research purposes.
> Authors are not responsible for misuse.

---

<div align="center">
  <sub><b>Memento Mori Project</b></sub><br>
  <sub>High-Resilience Distributed Systems Research</sub><br>
  <sub>Created by <b>Pslergy</b></sub>
</div>
