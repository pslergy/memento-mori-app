// lib/core/api_exceptions.dart
class UnauthorizedException implements Exception {
  final String message;
  UnauthorizedException(this.message);
}