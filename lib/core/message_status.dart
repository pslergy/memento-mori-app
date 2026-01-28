/// Message delivery statuses
/// Local statuses for UI, even if server is unavailable
class MessageStatus {
  // Логические состояния (стабилизация хранения)
  static const String localOnly = 'LOCAL_ONLY';   // Только локально, ещё не отправлено
  static const String delivered = 'DELIVERED';    // Доставлено хотя бы по одному каналу
  static const String synced = 'SYNCED';          // Подтверждено/синхронизировано с сетью
  static const String archived = 'ARCHIVED';      // Старое, можно stub или удалить локально

  // Local statuses (legacy / UI)
  static const String sentLocal = 'SENT_LOCAL'; // Sent locally
  static const String deliveredMesh = 'DELIVERED_MESH'; // ✓ Delivered via mesh
  static const String deliveredServer = 'DELIVERED_SERVER'; // ✓✓ Delivered to server

  // Legacy statuses (for backward compatibility)
  static const String sending = 'SENDING'; // 🕓 Sending…
  static const String deliveredToNetwork = 'DELIVERED_TO_NETWORK'; // ✓ Delivered to network
  static const String deliveredToParticipants = 'DELIVERED_TO_PARTICIPANTS'; // ✓✓ Delivered to participants
  
  /// Get display text for status
  static String getDisplayText(String status) {
    switch (status) {
      case localOnly:
        return '🕓 Pending';
      case delivered:
        return '✓ Delivered';
      case synced:
        return '✓✓ Synced';
      case archived:
        return '📦 Archived';
      case sentLocal:
        return '🕓 Sending…';
      case deliveredMesh:
        return '✓ Delivered';
      case deliveredServer:
        return '✓✓ Delivered';
      case sending:
        return '🕓 Sending…';
      case deliveredToNetwork:
        return '✓ Delivered to network';
      case deliveredToParticipants:
        return '✓✓ Delivered to participants';
      default:
        return status;
    }
  }
  
  /// Check if status is final (delivered)
  static bool isDelivered(String status) {
    return status == delivered ||
           status == synced ||
           status == deliveredMesh ||
           status == deliveredServer ||
           status == deliveredToNetwork ||
           status == deliveredToParticipants;
  }
  
  /// Get status icon for UI
  static String getStatusIcon(String status) {
    switch (status) {
      case localOnly:
      case sentLocal:
      case sending:
        return '🕓';
      case delivered:
      case deliveredMesh:
      case deliveredToNetwork:
        return '✓';
      case synced:
      case deliveredServer:
      case deliveredToParticipants:
        return '✓✓';
      case archived:
        return '📦';
      default:
        return '🕓';
    }
  }
}
