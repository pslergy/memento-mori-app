# Contributing to Memento Mori

First of all, thank you for your interest in **Memento Mori**.

This project is designed as a communication lifeline for restricted, degraded, or adversarial environments. Contributions are welcome, but the bar for quality, security, and architectural discipline is intentionally high.

Memento Mori is a **senior-led, security-first project**. Please read this document carefully before contributing.

---

## 🚀 How You Can Contribute

We are especially interested in contributions in the following areas:

* **Acoustic Transport Layer (Sonar Link)**
  Improving BFSK modulation, symbol timing, synchronization robustness, or Goertzel-based detection accuracy.

* **Security Review & Hardening**
  Auditing cryptographic flows, including AES-256-GCM usage, key lifecycle management, and offline threat models.

* **Native Android Optimization**
  Enhancing Kotlin Foreground Services, reducing wake locks, and improving battery behavior on low-end or vendor-modified devices.

If you are unsure where to start, open an Issue describing your background and interests.

---

## 🛠 Development Process

### 1️⃣ Branching Strategy

We use a simplified GitFlow model:

* `main`
  Production-ready, stable code only.

* `feature/<feature-name>`
  New functionality or experimental subsystems.

* `fix/<bug-name>`
  Bug fixes and stability improvements.

Direct commits to `main` are not accepted.

---

### 2️⃣ Pull Request (PR) Guidelines

All Pull Requests must follow these rules:

* **Atomic Commits**
  Each commit should represent a single logical change.

* **Security First**
  No plaintext secrets, no debug backdoors, no unencrypted logs.

* **Documentation Required**
  If you modify core logic, update:

  * Inline documentation, and/or
  * README / architecture notes where appropriate.

* **Real Device Testing**
  Whenever possible, validate mesh behavior on **at least two physical devices**. Emulators are insufficient for Bluetooth, Audio, and Wi-Fi Direct layers.

PRs that do not meet these criteria may be closed without review.

---

### 3️⃣ Coding Standards

#### Flutter / Dart

* Follow `flutter_lints`
* Deterministic state handling only
* Prefer **BLoC / Cubit / FSM-based logic**
* Avoid background work outside orchestrator control

#### Kotlin / Android

* Use **Coroutines** responsibly
* Fixed or bounded thread pools only
* No unbounded background execution
* Respect hardware interlocks (Bluetooth / Audio / Wi-Fi)

---

## 🛡️ Security & Privacy Principles

Memento Mori follows a **Zero-Knowledge** design philosophy.

### We do NOT accept:

* Centralized telemetry
* Hidden analytics
* User behavior tracking
* Cloud-dependent core features

All new code must preserve:

* Offline survivability
* Plausible deniability
* Minimal observable surface

If a feature weakens these guarantees, it will be rejected.

---

## 📫 Questions & Discussion

If you have questions about:

* Architecture
* Threat models
* Transport layers
* Identity & merge logic

Please open an **Issue** with the label `question`.

Clear, technical questions are always welcome.

---

*Memento Mori — In an era of total surveillance, privacy is a protocol.*
