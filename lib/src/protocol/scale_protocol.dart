import '../model/scale_reading.dart';

enum ScaleCommand { requestWeight, zero, tare, clearTare }

/// Commands are intentionally empty by default because scale control commands
/// are vendor-specific. Fill them only from a confirmed device manual.
class ScaleCommandSet {
  const ScaleCommandSet({
    this.requestWeight,
    this.zero,
    this.tare,
    this.clearTare,
  });

  final List<int>? requestWeight;
  final List<int>? zero;
  final List<int>? tare;
  final List<int>? clearTare;

  List<int>? bytesFor(ScaleCommand command) {
    final bytes = switch (command) {
      ScaleCommand.requestWeight => requestWeight,
      ScaleCommand.zero => zero,
      ScaleCommand.tare => tare,
      ScaleCommand.clearTare => clearTare,
    };
    return bytes == null ? null : List<int>.unmodifiable(bytes);
  }
}

enum ScaleProtocolErrorCode {
  frameTooLong,
  missingWeight,
  ambiguousWeight,
  invalidWeight,
  missingUnit,
}

class ScaleProtocolError {
  const ScaleProtocolError({
    required this.code,
    required this.message,
    required this.rawFrame,
  });

  final ScaleProtocolErrorCode code;
  final String message;
  final String rawFrame;

  @override
  String toString() => '${code.name}: $message';
}

class ScaleProtocolEvent {
  const ScaleProtocolEvent._({this.reading, this.error});

  const ScaleProtocolEvent.reading(ScaleReading value) : this._(reading: value);

  const ScaleProtocolEvent.error(ScaleProtocolError value)
      : this._(error: value);

  final ScaleReading? reading;
  final ScaleProtocolError? error;

  bool get ok => reading != null;
}

abstract interface class ScaleProtocol {
  ScaleCommandSet get commands;

  List<ScaleProtocolEvent> addBytes(
    List<int> bytes, {
    DateTime? receivedAt,
  });

  List<ScaleProtocolEvent> flush({DateTime? receivedAt});

  void reset();
}
