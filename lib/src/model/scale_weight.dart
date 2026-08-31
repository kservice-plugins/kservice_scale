enum ScaleUnit {
  kilogram('kg'),
  gram('g'),
  milligram('mg'),
  pound('lb'),
  ounce('oz');

  const ScaleUnit(this.symbol);

  final String symbol;

  static ScaleUnit? tryParse(String value) {
    return switch (value.trim().toLowerCase()) {
      'kg' => ScaleUnit.kilogram,
      'g' => ScaleUnit.gram,
      'mg' => ScaleUnit.milligram,
      'lb' || 'lbs' => ScaleUnit.pound,
      'oz' => ScaleUnit.ounce,
      _ => null,
    };
  }
}

/// Exact decimal weight reported by a scale.
///
/// A reading such as `1.250 kg` is stored as `1250` with three fraction
/// digits. Business code can therefore calculate prices without first losing
/// precision through a binary floating-point conversion.
class ScaleWeight {
  ScaleWeight({
    required this.unscaledValue,
    required this.fractionDigits,
    required this.unit,
  }) {
    if (fractionDigits < 0) {
      throw ArgumentError.value(
        fractionDigits,
        'fractionDigits',
        'must not be negative',
      );
    }
  }

  final BigInt unscaledValue;
  final int fractionDigits;
  final ScaleUnit unit;

  bool get isNegative => unscaledValue.isNegative;
  bool get isZero => unscaledValue == BigInt.zero;

  String get decimalValue {
    final negative = unscaledValue.isNegative;
    final digits =
        unscaledValue.abs().toString().padLeft(fractionDigits + 1, '0');
    final value = fractionDigits == 0
        ? digits
        : '${digits.substring(0, digits.length - fractionDigits)}.'
            '${digits.substring(digits.length - fractionDigits)}';
    return negative && !isZero ? '-$value' : value;
  }

  double get approximateValue => double.parse(decimalValue);

  factory ScaleWeight.parse(String value, ScaleUnit unit) {
    final normalized = value.trim().replaceAll(',', '.');
    if (!RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$').hasMatch(normalized)) {
      throw FormatException('Invalid scale weight: $value');
    }

    final negative = normalized.startsWith('-');
    final unsigned = normalized.replaceFirst(RegExp(r'^[+-]'), '');
    final parts = unsigned.split('.');
    final whole = parts.first.isEmpty ? '0' : parts.first;
    final fraction = parts.length == 2 ? parts.last : '';
    final digits = '$whole$fraction';
    var unscaled = BigInt.parse(digits);
    if (negative) {
      unscaled = -unscaled;
    }
    return ScaleWeight(
      unscaledValue: unscaled,
      fractionDigits: fraction.length,
      unit: unit,
    );
  }

  @override
  String toString() => '$decimalValue ${unit.symbol}';

  @override
  bool operator ==(Object other) {
    return other is ScaleWeight &&
        other.unscaledValue == unscaledValue &&
        other.fractionDigits == fractionDigits &&
        other.unit == unit;
  }

  @override
  int get hashCode => Object.hash(unscaledValue, fractionDigits, unit);
}
