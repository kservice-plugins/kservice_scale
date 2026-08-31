import 'dart:async';

import '../model/scale_reading.dart';
import '../protocol/scale_protocol.dart';
import '../transport/scale_transport.dart';

enum ScaleSessionState { disconnected, connecting, connected, closing }

class ScaleSession {
  ScaleSession({required this.transport, required this.protocol});

  final ScaleTransport transport;
  final ScaleProtocol protocol;

  final StreamController<ScaleProtocolEvent> _events =
      StreamController<ScaleProtocolEvent>.broadcast();
  final StreamController<ScaleSessionState> _states =
      StreamController<ScaleSessionState>.broadcast();

  StreamSubscription<List<int>>? _subscription;
  ScaleSessionState _state = ScaleSessionState.disconnected;
  bool _disposed = false;

  ScaleSessionState get state => _state;
  Stream<ScaleSessionState> get states => _states.stream;
  Stream<ScaleProtocolEvent> get events => _events.stream;
  Stream<ScaleReading> get readings => events
      .where((event) => event.reading != null)
      .map((event) => event.reading!);

  Future<void> connect() async {
    _ensureActive();
    if (_state != ScaleSessionState.disconnected) {
      throw StateError('Scale session is already active');
    }
    _setState(ScaleSessionState.connecting);
    try {
      await _subscription?.cancel();
      _subscription = null;
      protocol.reset();
      _subscription = transport.bytes.listen(
        (bytes) {
          for (final event in protocol.addBytes(bytes)) {
            _events.add(event);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _events.addError(error, stackTrace);
          _setState(ScaleSessionState.disconnected);
        },
        onDone: () => _setState(ScaleSessionState.disconnected),
      );
      await transport.open();
      _setState(ScaleSessionState.connected);
    } catch (error, stackTrace) {
      try {
        await _subscription?.cancel();
      } catch (_) {
        // Preserve the original connection error.
      }
      _subscription = null;
      protocol.reset();
      try {
        if (transport.isOpen) {
          await transport.close();
        }
      } catch (_) {
        // Preserve the original connection error.
      }
      _setState(ScaleSessionState.disconnected);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> send(ScaleCommand command) async {
    _ensureActive();
    if (_state != ScaleSessionState.connected) {
      throw StateError('Scale session is not connected');
    }
    final bytes = protocol.commands.bytesFor(command);
    if (bytes == null) {
      throw UnsupportedError(
        'Scale command ${command.name} is not configured for this protocol',
      );
    }
    await transport.write(bytes);
  }

  Future<void> close() async {
    if (_disposed || _state == ScaleSessionState.closing) {
      return;
    }
    if (_state != ScaleSessionState.disconnected) {
      _setState(ScaleSessionState.closing);
    }
    await _subscription?.cancel();
    _subscription = null;
    protocol.reset();
    try {
      if (transport.isOpen) {
        await transport.close();
      }
    } finally {
      _setState(ScaleSessionState.disconnected);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await close();
    _disposed = true;
    await _events.close();
    await _states.close();
  }

  void _setState(ScaleSessionState value) {
    _state = value;
    if (!_states.isClosed) {
      _states.add(value);
    }
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('Scale session has been disposed');
    }
  }
}
