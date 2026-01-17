Memento Mori: Autonomous Shadow Mesh Infrastructure
Resilient Decentralized Communication for Extreme Environments
Memento Mori — это не просто мессенджер, это отказоустойчивая ячеистая инфраструктура, спроектированная для работы в условиях полной деградации сетевых ресурсов. Проект реализует «теневой» слой связи под традиционным интернетом, используя синергию акустических сигналов, радио-всплесков и облачных шлюзов.
🧠 Core Engineering Innovation: The Tactical Orchestrator
Главная сложность Mesh-сетей на мобильных ОС — агрессивное энергосбережение и ограничения фоновых процессов. Я решил эту проблему через разработку Tactical Orchestrator (Decision Engine).
Key Logic Components:
Biological Burst-Mode: Система синхронизирует «циклы бодрствования» узлов. Вместо постоянного сканирования, устройства просыпаются одновременно для коротких высокоскоростных обменов данными (Burst Windows), что дает 90% экономии энергии.
Hardware Interlock Orchestration: Реализована логика исключительного доступа к HAL. Оркестратор предотвращает системные дедлоки на чипсетах MediaTek/Spreadtrum (Tecno, Huawei), разводя во времени работу Bluetooth-стека и Audio-тракта (Sonar).
GridScore Heuristic: Маршрутизация основана на динамическом скоринге соседа. Параметры: Hops to Internet (Градиент), Battery Level, Queue Pressure (нагрузка очереди).
🚀 The Multi-Layer Transport Stack
Система использует Heterogeneous Transport, переключаясь между слоями в зависимости от тактической ситуации:
1. Acoustic L2 Layer (Sonar Link)
Use-case: Обнаружение узлов в «радио-тишине» или при заблокированном Bluetooth.
Tech: Свой протокол поверх BFSK модуляции. Использование алгоритма Гёрцеля (Goertzel) для эффективного детектирования частот на мобильных CPU.
DFS (Dynamic Frequency Selection): Автоматический FFT-анализ спектра для выбора «тихого окна» (18kHz - 20kHz).
2. Control Plane (BLE Signaling)
Zero-Connect Discovery: Передача состояния градиента (Hops) и флага наличия данных прямо в Advertising Data. Узлы узнают топологию сети без установления соединения.
GATT Hardening: Специальный профиль подключения для обхода ошибки Android GATT Status 133.
3. Data Plane (Wi-Fi Direct & TCP)
Escalation Path: Если BLE обнаруживает аплинк, система автоматически поднимает Wi-Fi P2P группу для скоростной передачи накопленного Outbox.
Socket Binding: Принудительный биндинг на 0.0.0.0:55555 для решения проблемы «изолированных сокетов» на вендорских прошивках.
🧬 Identity & Data Integrity
Identity Transmigration Protocol
Решена проблема «слияния личностей» при выходе из оффлайна.
Ghost State: Локальная генерация Ed25519 ключей и инкубация сообщений в SQLite (WAL mode).
Landing Pass: Криптографическое обязательство (commitment), позволяющее позже привязать историю к Cloud-аккаунту.
Atomic Merge: Бэкенд (Node.js/Prisma) выполняет атомарную транзакцию по переносу владения сообщениями от ghostId к authId, предотвращая дублирование (Idempotency).
🔐 Security & Anti-Forensics
Camouflage: Приложение полностью маскируется под функциональный калькулятор.
Panic Trigger: Код принуждения (PIN) или Shake-to-Wipe (акселерометр) для мгновенного затирания ключей шифрования и базы данных.
Offline Entropy: Добавление случайного шума (padding) в пакеты для защиты от анализа трафика по размеру пакета.
🛠 Tech Stack & Engineering trade-offs
Flutter (Dart): Выбран для скорости разработки UI и управления кросс-платформенными FSM.
Native Kotlin: Использован для критических задач: FFT-анализа, управления сокетами и работы с Wi-Fi Direct API.
SQLite (WAL): Выбран вместо NoSQL решений (Hive/Realm) ради строгой ACID-транзакционности, критичной для целостности распределенной очереди сообщений.
👨‍💻 Research Goals
Проект исследует пределы возможностей современных мобильных устройств в создании Delay-Tolerant Networks (DTN). Основной упор сделан на автономность, скрытность и выживаемость софта в условиях системных ограничений ОС.
Author: Pslergy
Senior Software Architect | Distributed Systems | Hardware Interop
