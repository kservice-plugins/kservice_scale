import 'dart:async';
import 'dart:io';

import 'scale_transport.dart';

class TcpScaleTransport implements ScaleTransport {
  TcpScaleTransport({
    required this.host,
    required this.port,
    this.connectTimeout = const Duration(seconds: 3),
  }) {
    if (host.trim().isEmpty) {
      throw const ScaleTransportException(
        code: ScaleTransportErrorCode.invalidConfiguration,
        message: 'TCP host must not be empty',
      );
    }
    if (port < 1 || port > 65535) {
      throw ScaleTransportException(
        code: ScaleTransportErrorCode.invalidConfiguration,
        message: 'TCP port must be between 1 and 65535: $port',
      );
    }
  }

  final String host;
  final int port;
  final Duration connectTimeout;

  final StreamController<List<int>> _bytes =
      StreamController<List<int>>.broadcast();
  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;

  @override
  String get id => 'tcp:${host.trim()}:$port';

  @override
  bool get isOpen => _socket != null;

  @override
  Stream<List<int>> get bytes => _bytes.stream;

  @override
  Future<void> open() async {
    if (isOpen) {
      return;
    }
    try {
      final socket = await Socket.connect(
        host.trim(),
        port,
        timeout: connectTimeout,
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _subscription = socket.listen(
        _bytes.add,
        onError: _bytes.addError,
        onDone: () {
          _subscription = null;
          _socket = null;
          _bytes.addError(
            const ScaleTransportException(
              code: ScaleTransportErrorCode.disconnected,
              message: 'TCP scale connection was closed by the remote device',
            ),
          );
        },
        cancelOnError: false,
      );
    } catch (error) {
      _socket?.destroy();
      _socket = null;
      throw ScaleTransportException(
        code: ScaleTransportErrorCode.openFailed,
        message: 'Failed to connect to scale at ${host.trim()}:$port',
        cause: error,
      );
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    final socket = _socket;
    if (socket == null) {
      throw const ScaleTransportException(
        code: ScaleTransportErrorCode.writeFailed,
        message: 'TCP scale connection is not open',
      );
    }
    try {
      socket.add(bytes);
      await socket.flush();
    } catch (error) {
      throw ScaleTransportException(
        code: ScaleTransportErrorCode.writeFailed,
        message: 'Failed to write to TCP scale connection',
        cause: error,
      );
    }
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await socket.close();
      socket.destroy();
    }
  }
}
