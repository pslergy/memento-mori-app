<div align="center">

# 💀 Memento Mori  
### Resilient Offline-First Mesh Infrastructure

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://flutter.dev)
[![Status](https://img.shields.io/badge/Status-Research%20Alpha-orange.svg)]()
[![Website](https://img.shields.io/badge/Website-GitHub%20Pages-blue.svg)](https://pslergy.github.io/memento-mori-app/)

**Autonomous Decentralized Communication for Extreme Environments**  
*Delay-Tolerant • Zero-Trust • Air-Gapped Capable*

<br>

<img src="assets/screenshots/1.jpg" width="220" alt="Radar UI"/>
<img src="assets/screenshots/2.jpg" width="220" alt="Chat UI"/>
<img src="assets/screenshots/3.jpg" width="220" alt="Mesh Settings"/>
<img src="assets/screenshots/4.jpg" width="220" alt="Mesh Settings"/>
<img src="assets/screenshots/5.jpg" width="220" alt="Mesh Settings"/>

</div>

---

## ⚠️ RESEARCH PREVIEW — NOT A PRODUCTION RELEASE

> This is an independent research project exploring the limits of mobile ad-hoc networking. The code is published for educational purposes and peer review.  
> **The system is designed for research in Delay-Tolerant Networks (DTN) and operates without centralized infrastructure.**

---

## 🧠 Core Research Areas

### 1️⃣ Hardware-Aware Transport Layer
Standard mobile networking APIs assume persistent connectivity. This project explores techniques for maintaining communication under:
- Aggressive power management (vendor-specific background execution limits)
- Unreliable radio environments (packet loss, interference, device mobility)
- Hardware fragmentation across different Android implementations

### 2️⃣ Multi-Layer Hybrid Transport
- **BLE Control Plane:** Zero-connect topology discovery
- **Wi-Fi Direct Data Plane:** On-demand high-bandwidth escalation
- **Acoustic Channel (Experimental):** Ultrasonic close-range exchange for radio-free scenarios

### 3️⃣ Distributed Consistency Without Central Coordination
- **Store-and-Forward** with local persistent queues
- **Epidemic propagation** with anti-entropy mechanisms
- **CRDT-based** eventual consistency for partitioned networks

### 4️⃣ Local Data Protection
Research into protecting data on devices that may be physically compromised:
- **Dual-path storage:** Separate data contexts with distinct access methods
- **Selective data removal:** Targeted key erasure
- **Offline identity:** Locally-managed cryptographic identities without external dependencies

### 5️⃣ Network Layer Resilience
Exploration of techniques for maintaining connectivity under adversarial network conditions:
- **Transport diversity:** Multiple fallback paths
- **Traffic pattern obfuscation:** Alignment with common protocols
- **Adaptive routing:** Swarm-level learning of viable paths

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

## 🛠 Tech Stack

- **Language:** Dart (Flutter) + Kotlin (Platform Channels)
- **Architecture:** Clean Architecture + BLoC
- **Database:** SQLite (Drift, WAL Mode)
- **Cryptography:** `pointycastle`, `cryptography`
- **Signal Processing:** Goertzel Algorithm

---

## 📥 Getting Started

### Prerequisites
- Flutter SDK 3.x+
- Android device (API 26+)
- Physical devices required for transport testing (emulator support limited)

### Build
```bash
git clone https://github.com/pslergy/memento-mori-app
cd memento-mori-app
flutter pub get
flutter build apk --release
📚 Documentation
Document	Description
ARCHITECTURE.md	System design and transport layers
WHY_NOT_SIGNAL.md	Design rationale and comparisons
SECURITY.md	Threat model and cryptography
🤝 Contributing
This is a research project. Contributions in the following areas are welcome:

Digital Signal Processing optimization

Android transport behavior analysis

Cryptographic implementation review

Please read CONTRIBUTING.md before opening issues.

📄 License
GNU General Public License v3.0 — see LICENSE for details.

This license ensures the software remains free and open for research and educational use.

<div align="center">
Memento Mori — Remember that systems must survive

Independent research project

</div> ```
