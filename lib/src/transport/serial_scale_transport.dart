import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libserialport/libserialport.dart';

import 'scale_transport.dart';

enum ScaleSerialParity { none, odd, even, mark, space }

enum ScaleSerialFlowControl { none, xonXoff, rtsCts, dtrDsr }

enum ScaleSerialDeviceType { native, usb, bluetooth, unknown }

class ScaleSerialSettings {
  const ScaleSerialSettings({
    this.baudRate = 9600,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = ScaleSerialParity.none,
    this.flowControl = ScaleSerialFlowControl.none,
    this.dtr = false,
    this.rts = false,
    this.writeTimeout = const Duration(seconds: 2),
    this.readPollInterval = const Duration(milliseconds: 100),
  });

  final int baudRate;
  final int dataBits;
  final int stopBits;
  final ScaleSerialParity parity;
  final ScaleSerialFlowControl flowControl;
  final bool dtr;
  final bool rts;
  final Duration writeTimeout;
  final Duration readPollInterval;

  void validate() {
    if (baudRate <= 0) {
      throw ScaleTransportException(
        code: ScaleTransportErrorCode.invalidConfiguration,
        message: 'Serial baud rate must be positive: $baudRate',
      );
    }
    if (dataBits < 5 || dataBits > 8) {
      throw ScaleTransportException(
        code: ScaleTransportErrorCode.invalidConfiguration,
        message: 'Serial data bits must be between 5 and 8: $dataBits',
      );
    }
    if (stopBits != 1 && stopBits != 2) {
      throw ScaleTransportException(
        code: ScaleTransportErrorCode.invalidConfiguration,
        message: 'Serial stop bits must be 1 or 2: $stopBits',
      );
    }
  }
}

class SerialScaleDevice {
  const SerialScaleDevice({
    required this.name,
    required this.type,
    this.description,
    this.vendorId,
    this.productId,
    this.manufacturer,
    this.productName,
    this.serialNumber,
    this.macAddress,
  });

  final String name;
  final ScaleSerialDeviceType type;
  final String? description;
  final int? vendorId;
  final int? productId;
  final String? manufacturer;
  final String? productName;
  final String? serialNumber;
  final String? macAddress;

  String get displayName {
    final label = [manufacturer, productName]
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .join(' ');
    return label.isEmpty ? (description ?? name) : '$label ($name)';
  }
}

List<SerialScaleDevice> listSerialScaleDevices() {
  _ensureDesktopSerialPlatform();
  final devices = <SerialScaleDevice>[];
  for (final name in SerialPort.availablePorts) {
    final port = SerialPort(name);
    try {
      devices.add(
        SerialScaleDevice(
          name: name,
          type: _deviceType(port.transport),
          description: port.description,
          vendorId: port.vendorId,
          productId: port.productId,
          manufacturer: port.manufacturer,
          productName: port.productName,
          serialNumber: port.serialNumber,
          macAddress: port.macAddress,
        ),
      );
    } finally {
      port.dispose();
    }
  }
  return devices;
}

class SerialScaleTransport implements ScaleTransport {
  SerialScaleTransport({
    required this.portName,
    this.settings = const ScaleSerialSettings(),
  });

  final String portName;
  final ScaleSerialSettings settings;

  final StreamController<List<int>> _bytes =
      StreamController<List<int>>.broadcast();
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _subscription;
  bool _isOpen = false;

  @override
  String get id => 'serial:$portName:${settings.baudRate}';

  @override
  bool get isOpen => _isOpen;

  @override
  Stream<List<int>> get bytes => _bytes.stream;

  @override
  Future<void> open() async {
    if (_isOpen) {
      return;
    }
    _ensureDesktopSerialPlatform();
    settings.validate();
    if (portName.trim().isEmpty) {
      throw const ScaleTransportException(
        code: ScaleTransportErrorCode.invalidConfiguration,
        message: 'Serial port name must not be empty',
      );
    }

    final port = SerialPort(portName.trim());
    try {
      if (!port.openReadWrite()) {
        throw ScaleTransportException(
          code: ScaleTransportErrorCode.openFailed,
          message: 'Failed to open serial scale port ${portName.trim()}: '
              '${SerialPort.lastError?.message ?? 'unknown error'}',
        );
      }
      final config = SerialPortConfig()
        ..baudRate = settings.baudRate
        ..bits = settings.dataBits
        ..stopBits = settings.stopBits
        ..parity = _parity(settings.parity)
        ..setFlowControl(_flowControl(settings.flowControl))
        ..dtr = settings.dtr ? SerialPortDtr.on : SerialPortDtr.off
        ..rts = settings.rts ? SerialPortRts.on : SerialPortRts.off;
      port.config = config;

      final reader = SerialPortReader(
        port,
        timeout: settings.readPollInterval.inMilliseconds.clamp(1, 30000),
      );
      _port = port;
      _reader = reader;
      _isOpen = true;
      _subscription = reader.stream.listen(
        _bytes.add,
        onError: _bytes.addError,
        onDone: () {
          if (_isOpen) {
            _isOpen = false;
            _bytes.addError(
              const ScaleTransportException(
                code: ScaleTransportErrorCode.disconnected,
                message: 'Serial scale connection stopped receiving data',
              ),
            );
          }
        },
        cancelOnError: false,
      );
    } catch (error) {
      if (port.isOpen) {
        port.close();
      }
      port.dispose();
      if (error is ScaleTransportException) {
        rethrow;
      }
      throw ScaleTransportException(
        code: ScaleTransportErrorCode.openFailed,
        message: 'Failed to configure serial scale port ${portName.trim()}',
        cause: error,
      );
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    final port = _port;
    if (!_isOpen || port == null) {
      throw const ScaleTransportException(
        code: ScaleTransportErrorCode.writeFailed,
        message: 'Serial scale connection is not open',
      );
    }
    try {
      var offset = 0;
      final data = Uint8List.fromList(bytes);
      while (offset < data.length) {
        final written = port.write(
          Uint8List.sublistView(data, offset),
          timeout: settings.writeTimeout.inMilliseconds.clamp(1, 30000),
        );
        if (written <= 0) {
          throw StateError('Serial write returned $written bytes');
        }
        offset += written;
      }
      port.drain();
    } catch (error) {
      throw ScaleTransportException(
        code: ScaleTransportErrorCode.writeFailed,
        message: 'Failed to write to serial scale port $portName',
        cause: error,
      );
    }
  }

  @override
  Future<void> close() async {
    _isOpen = false;
    await _subscription?.cancel();
    _subscription = null;
    _reader?.close();
    _reader = null;
    final port = _port;
    _port = null;
    if (port != null) {
      if (port.isOpen) {
        port.close();
      }
      port.dispose();
    }
  }
}

void _ensureDesktopSerialPlatform() {
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    throw const ScaleTransportException(
      code: ScaleTransportErrorCode.unsupportedPlatform,
      message: 'Desktop serial transport supports Windows, macOS, and Linux. '
          'Use AndroidUsbSerialScaleTransport for Android USB serial devices.',
    );
  }
}

ScaleSerialDeviceType _deviceType(int value) {
  return switch (value) {
    SerialPortTransport.native => ScaleSerialDeviceType.native,
    SerialPortTransport.usb => ScaleSerialDeviceType.usb,
    SerialPortTransport.bluetooth => ScaleSerialDeviceType.bluetooth,
    _ => ScaleSerialDeviceType.unknown,
  };
}

int _parity(ScaleSerialParity value) {
  return switch (value) {
    ScaleSerialParity.none => SerialPortParity.none,
    ScaleSerialParity.odd => SerialPortParity.odd,
    ScaleSerialParity.even => SerialPortParity.even,
    ScaleSerialParity.mark => SerialPortParity.mark,
    ScaleSerialParity.space => SerialPortParity.space,
  };
}

int _flowControl(ScaleSerialFlowControl value) {
  return switch (value) {
    ScaleSerialFlowControl.none => SerialPortFlowControl.none,
    ScaleSerialFlowControl.xonXoff => SerialPortFlowControl.xonXoff,
    ScaleSerialFlowControl.rtsCts => SerialPortFlowControl.rtsCts,
    ScaleSerialFlowControl.dtrDsr => SerialPortFlowControl.dtrDsr,
  };
}
