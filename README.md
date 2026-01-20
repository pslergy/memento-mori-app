<div align="center">

# Memento Mori
### Autonomous Shadow Mesh Infrastructure

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://flutter.dev)
[![Status](https://img.shields.io/badge/Status-Research%20Alpha-orange.svg)]()
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)

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
> The protocol implementation, database schema, and routing logic may undergo breaking changes. This software is designed for research and testing of **Delay-Tolerant Networks (DTN)** and is not yet recommended for mission-critical use without prior validation.

---

## 💀 The Mission

**Memento Mori** is a fault-tolerant, autonomous mesh infrastructure designed to operate under **total network degradation**.

The project implements a **“shadow communication layer”** beneath the traditional Internet, leveraging a synergistic combination of acoustic signaling, radio-based discovery, and cloud gateways when available. It is built for environments where connectivity is intermittent, hostile, monitored, or deliberately suppressed.

---

## 🧠 Core Engineering Innovation

### 1. Tactical Orchestrator (Decision Engine)
The primary challenge of mobile mesh networks is **surviving the operating system**. Aggressive power management (Doze mode) and shared hardware resources (Bluetooth/Audio/Wi-Fi) often kill background mesh processes.

Memento Mori solves this via a deterministic **Hardware Interlock**:
*   **Anti-Deadlock Logic:** Enforces exclusive HAL access to prevent Bluetooth GATT status 133 errors.
*   **Biological Burst-Mode:** Nodes synchronize wake cycles to exchange data in short, high-throughput bursts, saving up to **90% battery**.
*   **Crash Guard:** Prevents audio driver starvation during Sonar operations on specific chipsets (MediaTek/Spreadtrum).

### 2. Multi-Layer Hybrid Transport
The app dynamically switches transport layers based on tactical conditions:

*   **🦇 Acoustic Sonar (L2):** Air-gapped discovery using ultrasonic BFSK modulation (18-20kHz). Works in radio silence or RF-monitored zones using the Goertzel algorithm on the CPU.
*   **📡 BLE Control Plane:** "Zero-Connect" topology inference. Nodes broadcast gradient state (hop counts) directly in Advertising packets without establishing heavy connections.
*   **⚡ Wi-Fi Direct (Data Plane):** Automatic escalation. When a BLE link is verified, a high-bandwidth Wi-Fi group is formed to flush the message queue (Outbox) instantly.

### 3. Identity Transmigration
*   **Ghost State:** Fully functional offline identity (Ed25519) stored in SQLite (WAL mode).
*   **Atomic Merge:** When internet becomes available, the offline "Ghost" identity is cryptographically bound to a persistent ID without history loss or forks.

---

## 🗺️ Roadmap & Status

We are building a robust offline ecosystem. Current progress:

- [x] **Core:** BLE Zero-Connect Discovery & Advertising Parsing
- [x] **Core:** Hardware Interlock (GATT/Sonar conflict resolution)
- [x] **Transport:** Acoustic Sonar Layer (BFSK signaling)
- [x] **Transport:** Wi-Fi Direct auto-negotiation (Failover escalation)
- [x] **Security:** Ghost Identity & Local Encryption (SQLite WAL)
- [x] **UI:** Basic "Radar" interface and Chat view
- [ ] **Routing:** Stabilize Gradient Descent (Multi-hop reliability)
- [ ] **Security:** Implement Double Ratchet Algorithm for E2EE
- [ ] **Network:** LoRa WAN hardware integration (USB/UART)
- [ ] **UI:** Camouflage Mode (Calculator disguise polishing)

---

## 🐛 Known Issues (Work in Progress)

*   **Huawei/Xiaomi Devices:** Aggressive battery optimization ("Power Genie") may kill the background service after 10-15 minutes. *Workaround: Manual whitelist in settings required.*
*   **Audio Audibility:** In very quiet rooms, young people or pets might hear the lower bound of the ultrasonic handshake (~17.5kHz).
*   **Wi-Fi Direct:** Legacy devices (Android 9 and below) might experience slow group formation negotiation.

---

## 🛠 Tech Stack

*   **Language:** Dart (Flutter) + Kotlin (Native Channels).
*   **Architecture:** Clean Architecture + BLoC.
*   **Database:** SQLite (Direct FFI with WAL mode) for ACID compliance.
*   **Crypto:** `pointycastle` / `cryptography` (Ed25519, AES-GCM).

---

## 📥 Getting Started

### Prerequisites
*   Flutter SDK (3.x+)
*   Android Device (API 26+ recommended)
*   *Note: Emulator support is limited due to Bluetooth/Wi-Fi Direct requirements.*

### Installation

````bash
# 1. Clone the repository
git clone https://github.com/pslergy/memento-mori-app.git

# 2. Install dependencies
cd memento-mori-app
flutter pub get

# 3. Run on physical device
flutter run --release````

## 🤝 Contributing

This is an open research project. We welcome contributions, especially in:
*   **DSP / Audio signal processing:** Optimization of the Goertzel algorithm.
*   **Android HAL:** Handling specifics for Samsung/Pixel/Xiaomi hardware quirks.
*   **Security:** Cryptographic review and penetration testing.

See `CONTRIBUTING.md` (coming soon) for details.

---

## 📄 License

This project is licensed under the **GNU General Public License v3.0** - see the [LICENSE](LICENSE) file for details.

> **Disclaimer:** This software is provided "as is", without warranty of any kind. It is intended for educational and defensive research purposes. Authors are not responsible for any misuse of this technology.

---

<div align="center">
  <sub><b>Memento Mori Project</b></sub><br>
  <sub>High-Resilience Distributed Systems Research</sub>
  <br>
  <sub>Created by <b>Pslergy</b></sub>
</div>
