import 'scale_weight.dart';

enum ScaleStability { stable, unstable, unknown }

enum ScaleWeightMode { gross, net, tare, unknown }

enum ScaleCondition { normal, overload, underload }

class ScaleReading {
  const ScaleReading({
    required this.rawFrame,
    required this.receivedAt,
    required this.stability,
    required this.mode,
    required this.condition,
    this.weight,
  });

  final ScaleWeight? weight;
  final ScaleStability stability;
  final ScaleWeightMode mode;
  final ScaleCondition condition;
  final String rawFrame;
  final DateTime receivedAt;

  bool get isStable => stability == ScaleStability.stable;

  /// True only when the scale explicitly reports a stable, normal weight.
  bool get ready =>
      condition == ScaleCondition.normal && weight != null && isStable;

  bool canUse({bool allowUnknownStability = false}) {
    return condition == ScaleCondition.normal &&
        weight != null &&
        (isStable ||
            allowUnknownStability && stability == ScaleStability.unknown);
  }

  @override
  String toString() {
    return 'ScaleReading(weight: $weight, stability: $stability, '
        'mode: $mode, condition: $condition)';
  }
}
