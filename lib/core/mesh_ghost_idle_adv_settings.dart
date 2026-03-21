import 'package:shared_preferences/shared_preferences.dart';

/// Интервал **пульса BLE-рекламы в простое** (GHOST / RELAY, пустой outbox).
///
/// Зачем: в режиме «только реклама, без скана» узел должен оставаться видимым для соседей.
/// На части прошивок (часто Huawei/EMUI) стек может перестать реально слать advertising-кадры,
/// оставляя внутреннее состояние «ещё рекламируем». Тогда входящие почти не находят узел.
/// Периодический перезапуск той же tactical-рекламы «пробрасывает» эфир.
///
/// Больше секунд между пульсами → экономия батареи и меньше нагрузки на радио.
/// Меньше секунд → лучше в плотной сети / нестабильном BLE.
/// `0` — только стандартный watchdog (если реклама полностью упала по state), без пульса в простое.
class MeshGhostIdleAdvSettings {
  MeshGhostIdleAdvSettings._();

  static const String prefKey = 'mesh_ghost_idle_adv_keepalive_sec';

  /// Значение по умолчанию при первом запуске (совпадает с прежней константой в оркестраторе).
  static const int defaultSeconds = 45;

  /// Допустимые значения: 0 = выкл, иначе период в секундах.
  static const List<int> allowedSeconds = [0, 30, 45, 60, 90, 120];

  static Future<int> getSeconds() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getInt(prefKey);
    if (v == null) return defaultSeconds;
    if (allowedSeconds.contains(v)) return v;
    return defaultSeconds;
  }

  static Future<void> setSeconds(int sec) async {
    if (!allowedSeconds.contains(sec)) return;
    final p = await SharedPreferences.getInstance();
    await p.setInt(prefKey, sec);
  }

  /// Подписи для UI (русский, как в Mesh Control).
  static String labelForSeconds(int sec) {
    if (sec == 0) return 'Выключено (только восстановление при сбое)';
    if (sec == 30) return 'Каждые 30 с — плотная сеть';
    if (sec == 45) return 'Каждые 45 с — по умолчанию';
    if (sec == 60) return 'Каждые 60 с — умеренно';
    if (sec == 90) return 'Каждые 90 с — экономия';
    if (sec == 120) return 'Каждые 120 с — максимум экономии';
    return 'Каждые $sec с';
  }

  static String get explanationShort =>
      'Пульс BLE-рекламы, когда нечего отправлять: чтобы соседи продолжали вас видеть '
      '(особенно на Huawei). Реже — меньше расход батареи.';

  static String get explanationLong =>
      'Когда исходящая очередь пуста, призрак часто только **рекламирует** себя по BLE и не сканирует — '
      'так вы остаётесь в эфире для других. На некоторых телефонах реклама может «зависнуть» на уровне ОС: '
      'приложение думает, что всё ок, а кадры в эфир не уходят — тогда **входящие** до вас почти не доходят, '
      'пока что-то снова не запустит BLE.\n\n'
      'Эта настройка задаёт, как часто **мягко перезапускать** ту же рекламу в простое (пустой outbox). '
      '«Выключено» оставляет только авто-восстановление, если реклама полностью остановилась по состоянию стека. '
      'Короче интервал — заметнее в шумной сети, но чуть больше нагрузка на радио и батарею.';
}
