class NicknameTakenException implements Exception {
  final String message;
  NicknameTakenException([this.message = "This nickname is already claimed on the global grid."]);

  @override
  String toString() => "NicknameTakenException: $message";
}