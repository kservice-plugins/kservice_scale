import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'scale_transport.dart';
import 'serial_scale_transport.dart';

class AndroidUsbSerialDevice {
  const AndroidUsbSerialDevice({
    required this.deviceName,
    required this.deviceId,
    required this.portIndex,
    required this.vendorId,
    required this.productId,
    required this.driver,
    this.productName,
    this.manufacturer,
    this.serialNumber,
    this.interfaceCount,
  });

  final String deviceName;
  final int deviceId;
  final int portIndex;
  final int vendorId;
  final int productId;
  final String driver;
  final String? productName;
  final String? manufacturer;
  final String? serialNumber;
  final int? interfaceCount;

  String get displayName {
    final label = [manufacturer, productName]
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .join(' ');
    final name = label.isEmpty ? deviceName : label;
    return '$name (0x${vendorId.toRadixString(16).padLeft(4, '0')}/'
        '0x${productId.toRadixString(16).padLeft(4, '0')}, port $portIndex)';
  }

  factory AndroidUsbSerialDevice.fromMap(Map<Object?, Object?> map) {
    return AndroidUsbSerialDevice(
      deviceName: map['deviceName']! as String,
      deviceId: map['deviceId']! as int,
      portIndex: map['portIndex']! as int,
      vendorId: map['vendorId']! as int,
      productId: map['productId']! as int,
      driver: map['driver']! as String,
      productName: map['productName'] as String?,
      manufacturer: map['manufacturer'] as String?,
      serialNumber: map['serialNumber'] as String?,
      interfaceCount: map['interfaceCount'] as int?,
    );
  }
}

const MethodChannel _androidUsbChannel = MethodChannel('kservice_scale');
const EventChannel _androidUsbEvents = EventChannel(
  'kservice_scale/usb_serial_events',
);
Stream<Map<Object?, Object?>>? _sharedAndroidUsbEvents;
int _nextAndroidConnectionId = 0;

Stream<Map<Object?, Object?>> get _androidEvents =>
    _sharedAndroidUsbEvents ??= _androidUsbEvents
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => event as Map<Object?, Object?>)
        .asBroadcastStream();

Future<List<AndroidUsbSerialDevice>> listAndroidUsbSerialDevices() async {
  _ensureAndroidPlatform();
  try {
    final devices = await _androidUsbChannel.invokeListMethod<Object?>(
      'listUsbSerialDevices',
    );
    return [
      for (final device in devices ?? const [])
        if (device is Map)
          AndroidUsbSerialDevice.fromMap(Map<Object?, Object?>.from(device)),
    ];
  } on PlatformException catch (error) {
    throw _platformError(error, ScaleTransportErrorCode.deviceNotFound);
  }
}

class AndroidUsbSerialScaleTransport implements ScaleTransport {
  AndroidUsbSerialScaleTransport({
    required this.device,
    this.settings = const ScaleSerialSettings(),
    this.writeTimeout = const Duration(seconds: 2),
  });

  final AndroidUsbSerialDevice device;
  final ScaleSerialSettings settings;
  final Duration writeTimeout;

  final StreamController<List<int>> _bytes =
      StreamController<List<int>>.broadcast();
  StreamSubscription<Map<Object?, Object?>>? _subscription;
  String? _connectionId;
  String? _pendingConnectionId;

  @override
  String get id =>
      'android-usb-serial:${device.deviceName}:${device.portIndex}';

  @override
  bool get isOpen => _connectionId != null;

  @override
  Stream<List<int>> get bytes => _bytes.stream;

  @override
  Future<void> open() async {
    if (isOpen) {
      return;
    }
    _ensureAndroidPlatform();
    settings.validate();
    final connectionId =
        'scale-${DateTime.now().microsecondsSinceEpoch}-${_nextAndroidConnectionId++}';
    _subscription = _androidEvents
        .where((event) => event['connectionId'] == connectionId)
        .listen((event) {
      final data = event['data'];
      if (data is Uint8List) {
        _bytes.add(data);
      } else if (data is List<int>) {
        _bytes.add(Uint8List.fromList(data));
      }
      final error = event['error'];
      if (error != null) {
        _bytes.addError(
          ScaleTransportException(
            code: ScaleTransportErrorCode.openFailed,
            message: error.toString(),
          ),
        );
      }
      if (event['closed'] == true) {
        _connectionId = null;
        _pendingConnectionId = null;
      }
    });

    _pendingConnectionId = connectionId;
    try {
      await _androidUsbChannel.invokeMethod<void>('openUsbSerial', {
        'connectionId': connectionId,
        'deviceId': device.deviceId,
        'vendorId': device.vendorId,
        'productId': device.productId,
        'portIndex': device.portIndex,
        'baudRate': settings.baudRate,
        'dataBits': settings.dataBits,
        'stopBits': settings.stopBits,
        'parity': settings.parity.index,
        'flowControl': settings.flowControl.index,
        'dtr': settings.dtr,
        'rts': settings.rts,
      });
      if (_pendingConnectionId != connectionId) {
        throw const ScaleTransportException(
          code: ScaleTransportErrorCode.disconnected,
          message: 'Android USB serial scale disconnected while opening',
        );
      }
      _pendingConnectionId = null;
      _connectionId = connectionId;
    } on PlatformException catch (error) {
      _pendingConnectionId = null;
      await _subscription?.cancel();
      _subscription = null;
      throw _platformError(error, ScaleTransportErrorCode.openFailed);
    } on ScaleTransportException {
      _pendingConnectionId = null;
      await _subscription?.cancel();
      _subscription = null;
      rethrow;
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    final connectionId = _connectionId;
    if (connectionId == null) {
      throw const ScaleTransportException(
        code: ScaleTransportErrorCode.writeFailed,
        message: 'Android USB serial scale connection is not open',
      );
    }
    try {
      await _androidUsbChannel.invokeMethod<void>('writeUsbSerial', {
        'connectionId': connectionId,
        'data': Uint8List.fromList(bytes),
        'timeoutMs': writeTimeout.inMilliseconds.clamp(100, 30000),
      });
    } on PlatformException catch (error) {
      throw _platformError(error, ScaleTransportErrorCode.writeFailed);
    }
  }

  @override
  Future<void> close() async {
    final connectionId = _connectionId ?? _pendingConnectionId;
    _connectionId = null;
    _pendingConnectionId = null;
    try {
      if (connectionId != null) {
        await _androidUsbChannel.invokeMethod<void>('closeUsbSerial', {
          'connectionId': connectionId,
        });
      }
    } on PlatformException catch (error) {
      throw _platformError(error, ScaleTransportErrorCode.openFailed);
    } finally {
      await _subscription?.cancel();
      _subscription = null;
    }
  }
}

void _ensureAndroidPlatform() {
  if (!Platform.isAndroid) {
    throw const ScaleTransportException(
      code: ScaleTransportErrorCode.unsupportedPlatform,
      message: 'Android USB serial transport is only available on Android',
    );
  }
}

ScaleTransportException _platformError(
  PlatformException error,
  ScaleTransportErrorCode fallback,
) {
  final code = switch (error.code) {
    'device_not_found' => ScaleTransportErrorCode.deviceNotFound,
    'device_ambiguous' => ScaleTransportErrorCode.deviceAmbiguous,
    'invalid_argument' => ScaleTransportErrorCode.invalidConfiguration,
    'write_failed' => ScaleTransportErrorCode.writeFailed,
    _ => fallback,
  };
  return ScaleTransportException(
    code: code,
    message: error.message ?? 'Android USB serial operation failed',
    cause: error,
  );
}
