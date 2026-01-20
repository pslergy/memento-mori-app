# Contributing to Memento Mori

Thank you for your interest in **Memento Mori**.

Memento Mori is an independent research project exploring resilient, decentralized communication under **severely constrained and adversarial conditions**. The system is designed to operate where conventional assumptions about connectivity, power availability, and OS cooperation no longer hold.

Contributions are welcome, but please note that this project is **security-first, failure-aware, and architecturally conservative by design**.

---

## 🚀 Areas of Contribution

We are particularly interested in contributions in the following domains:

### 🔊 Acoustic Transport (Sonar Link)

Improvements to:

* BFSK modulation and symbol timing
* Clock drift tolerance and synchronization
* Goertzel-based detection accuracy and CPU efficiency
* Robustness in noisy or reverberant environments

Signal processing expertise is highly appreciated here.

---

### 🔐 Security Review & Hardening

Security contributions may include:

* Cryptographic flow auditing (AES-256-GCM, Ed25519)
* Key lifecycle analysis and offline identity guarantees
* Threat modeling for delay-tolerant, intermittently connected nodes
* Review of merge semantics between offline and online identity states

All security discussions are expected to be concrete and threat-model driven.

---

### 📱 Native Android & OS-Level Optimization

Help is welcome in areas such as:

* Foreground service stabilization under OEM power managers
* Wake-lock minimization and scheduling strategies
* Bluetooth, Audio, and Wi-Fi HAL contention mitigation
* Behavior analysis on low-end or vendor-modified devices (Xiaomi, Huawei, Tecno, etc.)

---

If you are unsure where to start, feel free to open an **Issue** describing your background and what area you are interested in exploring.

---

## 🛠 Development Workflow

### 1️⃣ Branching Model

We follow a simplified GitFlow-style approach:

* `main`
  Stable, production-grade research code only.

* `feature/<name>`
  New features, experimental subsystems, or architectural work.

* `fix/<name>`
  Bug fixes, performance improvements, and stability patches.

Direct commits to `main` are not accepted.

---

### 2️⃣ Pull Request Guidelines

All Pull Requests are expected to meet the following criteria:

* **Atomic Commits**
  Each commit should represent one logical, reviewable change.

* **Security Awareness**
  No plaintext secrets, debug backdoors, or unencrypted diagnostic output.

* **Documentation Alignment**
  Changes to core logic must be accompanied by:

  * Inline documentation, and/or
  * Updates to README or architecture notes when relevant.

* **Real Device Validation**
  Mesh behavior should be tested on **physical Android devices** whenever possible.
  Emulators are insufficient for Bluetooth, Audio, and Wi-Fi Direct layers.

Pull Requests that do not meet these expectations may be closed without detailed review.

---

## 📐 Coding Standards

### Flutter / Dart

* Follow `flutter_lints`
* Deterministic state management only
* Prefer **BLoC / Cubit / explicit FSMs**
* Avoid background execution outside orchestrator control

---

### Kotlin / Android

* Structured concurrency using **Coroutines**
* Bounded thread pools only
* No unbounded background execution
* Respect hardware interlocks between Bluetooth, Audio, and Wi-Fi subsystems

---

## 🛡️ Security & Privacy Principles

Memento Mori adheres to a **Zero-Knowledge, Offline-First** design philosophy.

The project does **not** accept contributions that introduce:

* Centralized telemetry
* Hidden analytics
* Behavioral tracking
* Cloud-dependent core functionality

All accepted contributions must preserve:

* Offline survivability
* Minimal observable surface
* Plausible deniability under inspection

Features that weaken these guarantees will not be merged.

---

## 📫 Questions & Technical Discussion

For questions related to:

* System architecture
* Threat models
* Transport layers
* Identity and merge semantics

Please open an **Issue** with the label `question`.

Clear, technically grounded discussions are always welcome.

---

*Memento Mori — In environments where infrastructure fails, protocol design becomes survival.*
