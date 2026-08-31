/// Byte transport implemented by serial, USB, Bluetooth, or vendor SDK
/// adapters. The protocol core does not choose a platform transport.
abstract interface class ScaleTransport {
  String get id;

  bool get isOpen;

  /// Must be listenable before [open] so devices that publish immediately do
  /// not lose their first frame.
  Stream<List<int>> get bytes;

  Future<void> open();

  Future<void> write(List<int> bytes);

  Future<void> close();
}

enum ScaleTransportErrorCode {
  unsupportedPlatform,
  invalidConfiguration,
  deviceNotFound,
  deviceAmbiguous,
  openFailed,
  disconnected,
  writeFailed,
}

class ScaleTransportException implements Exception {
  const ScaleTransportException({
    required this.code,
    required this.message,
    this.cause,
  });

  final ScaleTransportErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => '${code.name}: $message';
}
