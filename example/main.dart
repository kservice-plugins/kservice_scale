// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:kservice_scale/kservice_scale_core.dart';

void main() {
  final protocol = GenericAsciiScaleProtocol();
  final chunks = [
    ascii.encode('ST,GS, 1.'),
    ascii.encode('250kg\r\nUS,NT,-0.030 kg\r\nOL\r\n'),
  ];

  for (final chunk in chunks) {
    for (final event in protocol.addBytes(chunk)) {
      final reading = event.reading;
      if (reading != null) {
        print(
          '${reading.weight ?? reading.condition.name} '
          'stable=${reading.isStable} ready=${reading.ready}',
        );
      } else {
        print('parse error: ${event.error}');
      }
    }
  }
}
