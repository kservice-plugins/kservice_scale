import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kservice_scale/kservice_scale_core.dart';

void main() {
  group('DahuaScaleProtocol', () {
    test('takes the first numeric field as net weight by default', () {
      final protocol = DahuaScaleProtocol();
      final events =
          protocol.addBytes(ascii.encode(' 0065    000     000\r'));

      expect(events, hasLength(1));
      final reading = events.single.reading;
      expect(reading, isNotNull);
      expect(reading!.weight!.decimalValue, '0.065');
      expect(reading.weight!.unit, ScaleUnit.kilogram);
      expect(reading.mode, ScaleWeightMode.net);
      expect(reading.condition, ScaleCondition.normal);
      expect(reading.ready, isTrue);
    });

    test('supports gram / integer configuration', () {
      final protocol = DahuaScaleProtocol(
        unit: ScaleUnit.gram,
        fractionDigits: 0,
      );
      final events =
          protocol.addBytes(ascii.encode(' 0065    000     000\r'));

      expect(events.single.reading!.weight!.decimalValue, '65');
      expect(events.single.reading!.weight!.unit, ScaleUnit.gram);
    });

    test('handles frames split across chunks', () {
      final protocol = DahuaScaleProtocol();
      expect(protocol.addBytes(ascii.encode(' 006')), isEmpty);

      final events = protocol.addBytes(ascii.encode('5    000     000\r'));
      expect(events, hasLength(1));
      expect(events.single.reading!.weight!.decimalValue, '0.065');
    });

    test('emits one reading per frame', () {
      final protocol = DahuaScaleProtocol();
      final events = protocol.addBytes(
        ascii.encode(' 0065    000     000\r 0325    000     000\r'),
      );

      expect(events, hasLength(2));
      expect(events[0].reading!.weight!.decimalValue, '0.065');
      expect(events[1].reading!.weight!.decimalValue, '0.325');
    });

    test('reports missing weight for non-numeric frame', () {
      final protocol = DahuaScaleProtocol();
      final events = protocol.addBytes(ascii.encode('----\r'));

      expect(events.single.error?.code, ScaleProtocolErrorCode.missingWeight);
    });

    test('respects weightFieldIndex', () {
      final protocol = DahuaScaleProtocol(
        weightFieldIndex: 1,
        fractionDigits: 0,
      );
      final events =
          protocol.addBytes(ascii.encode(' 0065    012     000\r'));

      expect(events.single.reading!.weight!.decimalValue, '12');
    });

    test('can report unknown stability when assumeStable is false', () {
      final protocol = DahuaScaleProtocol(assumeStable: false);
      final events =
          protocol.addBytes(ascii.encode(' 0065    000     000\r'));

      final reading = events.single.reading!;
      expect(reading.stability, ScaleStability.unknown);
      expect(reading.ready, isFalse);
    });
  });
}
