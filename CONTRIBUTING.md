# Contributing to Memento Mori

First of all, thank you for showing interest in Memento Mori. This project aims to provide a lifeline for communication in restricted environments, and your help is vital.

As a Senior-led project, we maintain high standards for code quality, security, and architectural integrity.

## 🚀 How Can You Help?
*   **Acoustic Layer:** Improving the FSK modulation for the Sonar Link.
*   **Security Audits:** Reviewing the AES-256-GCM implementation.
*   **Native Optimization:** Enhancing the Kotlin Foreground Service for better battery life on low-end devices.

## 🛠 Development Process

### 1. Branching Strategy
We use a simplified GitFlow. 
*   `main` — Production-ready code only.
*   `feature/feature-name` — New features.
*   `fix/bug-name` — Bug fixes.

### 2. Pull Request (PR) Guidelines
*   **Atomic Commits:** Keep your commits small and focused.
*   **Security First:** Ensure no sensitive data or unencrypted logs are included.
*   **Documentation:** Update the README or inline comments if you change core logic.
*   **Testing:** Verify mesh connectivity on at least two physical devices (if possible).

### 3. Coding Standards
*   **Flutter:** Use `flutter_lints`. Follow the BLoC/Cubit pattern for state management.
*   **Kotlin:** Maintain the use of Coroutines and fixed thread pools for networking to prevent hardware overloads.

## 🛡️ Security & Privacy
Since this is a privacy-focused tool, please ensure all new code adheres to the **Zero-Knowledge** principle. We do not accept features that require centralized telemetry or user data collection.

## 📫 Questions?
If you have questions about the architecture or threat model, please open an **Issue** with the `question` label.

---
*Memento Mori — In an era of total surveillance, privacy is a protocol.*
