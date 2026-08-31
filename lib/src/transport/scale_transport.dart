/// Byte transport implemented by serial, USB, Bluetooth, or vendor SDK
/// adapters. The protocol core does not choose a platform transport.
abstract interface class ScaleTransport {
  String get id;

  bool get isOpen;

  Stream<List<int>> get bytes;

  Future<void> open();

  Future<void> write(List<int> bytes);

  Future<void> close();
}
