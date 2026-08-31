import 'dart:convert';

import '../model/scale_reading.dart';
import '../model/scale_weight.dart';
import 'scale_protocol.dart';

/// Conservative parser for common line-based ASCII scale frames.
///
/// Supported examples include `ST,GS, 1.250kg`, `US,NT,-0.030 kg`, and
/// `+1250 g`. Frames with more than one numeric value are rejected instead of
/// guessing which value is the weight.
class GenericAsciiScaleProtocol implements ScaleProtocol {
  GenericAsciiScaleProtocol({
    this.defaultUnit = ScaleUnit.kilogram,
    this.allowUnitless = false,
    this.maxFrameBytes = 256,
    this.commands = const ScaleCommandSet(),
    List<int> terminators = const [0x0d, 0x0a],
  }) : _terminators = Set<int>.unmodifiable(terminators) {
    if (maxFrameBytes < 16 || maxFrameBytes > 4096) {
      throw ArgumentError.value(
        maxFrameBytes,
        'maxFrameBytes',
        'must be between 16 and 4096',
      );
    }
    if (_terminators.isEmpty) {
      throw ArgumentError.value(
          terminators, 'terminators', 'must not be empty');
    }
  }

  static final RegExp _numberPattern = RegExp(
    r'[-+]?(?:\d+(?:[.,]\d+)?|[.,]\d+)',
  );
  static final RegExp _unitPattern = RegExp(
    r'(?:^|[^A-Z])(kg|mg|g|lbs?|oz)(?=$|[^A-Z])',
    caseSensitive: false,
  );
  static final RegExp _stablePattern = RegExp(
    r'(^|[^A-Z])(S|ST|STABLE)(?=$|[^A-Z])',
  );
  static final RegExp _unstablePattern = RegExp(
    r'(^|[^A-Z])(U|US|UNSTABLE|MOTION)(?=$|[^A-Z])',
  );
  static final RegExp _grossPattern = RegExp(
    r'(^|[^A-Z])(G|GS|GROSS)(?=$|[^A-Z])',
  );
  static final RegExp _netPattern = RegExp(
    r'(^|[^A-Z])(N|NT|NET)(?=$|[^A-Z])',
  );
  static final RegExp _tarePattern = RegExp(
    r'(^|[^A-Z])(T|TR|TARE)(?=$|[^A-Z])',
  );
  static final RegExp _overloadPattern = RegExp(
    r'(^|[^A-Z])(OL|OVER|OVERLOAD)(?=$|[^A-Z])|\+{4,}',
  );
  static final RegExp _underloadPattern = RegExp(
    r'(^|[^A-Z])(UL|UNDER|UNDERLOAD)(?=$|[^A-Z])|-{4,}',
  );

  final ScaleUnit defaultUnit;
  final bool allowUnitless;
  final int maxFrameBytes;
  final Set<int> _terminators;
  final List<int> _buffer = [];
  bool _discardingOversizedFrame = false;

  @override
  final ScaleCommandSet commands;

  @override
  List<ScaleProtocolEvent> addBytes(
    List<int> bytes, {
    DateTime? receivedAt,
  }) {
    final events = <ScaleProtocolEvent>[];
    for (final byte in bytes) {
      if (byte < 0 || byte > 255) {
        throw ArgumentError.value(byte, 'bytes', 'must contain byte values');
      }
      if (_terminators.contains(byte)) {
        if (_discardingOversizedFrame) {
          _discardingOversizedFrame = false;
          continue;
        }
        if (_buffer.isNotEmpty) {
          events.add(_parseBufferedFrame(receivedAt));
        }
        continue;
      }
      if (_discardingOversizedFrame) {
        continue;
      }
      _buffer.add(byte);
      if (_buffer.length > maxFrameBytes) {
        final raw = latin1.decode(_buffer, allowInvalid: true);
        _buffer.clear();
        _discardingOversizedFrame = true;
        events.add(
          ScaleProtocolEvent.error(
            ScaleProtocolError(
              code: ScaleProtocolErrorCode.frameTooLong,
              message: 'Scale frame exceeds $maxFrameBytes bytes',
              rawFrame: raw,
            ),
          ),
        );
      }
    }
    return events;
  }

  @override
  List<ScaleProtocolEvent> flush({DateTime? receivedAt}) {
    if (_discardingOversizedFrame || _buffer.isEmpty) {
      return const [];
    }
    return [_parseBufferedFrame(receivedAt)];
  }

  @override
  void reset() {
    _buffer.clear();
    _discardingOversizedFrame = false;
  }

  ScaleProtocolEvent _parseBufferedFrame(DateTime? receivedAt) {
    final rawFrame = latin1.decode(_buffer, allowInvalid: true).trim();
    _buffer.clear();
    final upper = rawFrame.toUpperCase();
    final condition = _condition(upper);
    final stability = _stability(upper);
    final mode = _mode(upper);

    if (condition != ScaleCondition.normal) {
      return ScaleProtocolEvent.reading(
        ScaleReading(
          rawFrame: rawFrame,
          receivedAt: receivedAt ?? DateTime.now(),
          stability: stability,
          mode: mode,
          condition: condition,
        ),
      );
    }

    final numberMatches = _numberPattern.allMatches(rawFrame).toList();
    if (numberMatches.isEmpty) {
      return _error(
        ScaleProtocolErrorCode.missingWeight,
        'Scale frame does not contain a weight',
        rawFrame,
      );
    }
    if (numberMatches.length > 1) {
      return _error(
        ScaleProtocolErrorCode.ambiguousWeight,
        'Scale frame contains more than one numeric value',
        rawFrame,
      );
    }

    final unitMatch = _unitPattern.firstMatch(rawFrame);
    final unit = unitMatch == null
        ? (allowUnitless ? defaultUnit : null)
        : ScaleUnit.tryParse(unitMatch.group(1)!);
    if (unit == null) {
      return _error(
        ScaleProtocolErrorCode.missingUnit,
        'Scale frame does not contain a supported unit',
        rawFrame,
      );
    }

    final value = numberMatches.single.group(0)!;
    try {
      return ScaleProtocolEvent.reading(
        ScaleReading(
          weight: ScaleWeight.parse(value, unit),
          rawFrame: rawFrame,
          receivedAt: receivedAt ?? DateTime.now(),
          stability: stability,
          mode: mode,
          condition: condition,
        ),
      );
    } on FormatException {
      return _error(
        ScaleProtocolErrorCode.invalidWeight,
        'Scale frame contains an invalid weight',
        rawFrame,
      );
    }
  }

  ScaleProtocolEvent _error(
    ScaleProtocolErrorCode code,
    String message,
    String rawFrame,
  ) {
    return ScaleProtocolEvent.error(
      ScaleProtocolError(code: code, message: message, rawFrame: rawFrame),
    );
  }

  ScaleStability _stability(String frame) {
    if (_unstablePattern.hasMatch(frame)) {
      return ScaleStability.unstable;
    }
    if (_stablePattern.hasMatch(frame)) {
      return ScaleStability.stable;
    }
    return ScaleStability.unknown;
  }

  ScaleWeightMode _mode(String frame) {
    if (_netPattern.hasMatch(frame)) {
      return ScaleWeightMode.net;
    }
    if (_grossPattern.hasMatch(frame)) {
      return ScaleWeightMode.gross;
    }
    if (_tarePattern.hasMatch(frame)) {
      return ScaleWeightMode.tare;
    }
    return ScaleWeightMode.unknown;
  }

  ScaleCondition _condition(String frame) {
    if (_overloadPattern.hasMatch(frame)) {
      return ScaleCondition.overload;
    }
    if (_underloadPattern.hasMatch(frame)) {
      return ScaleCondition.underload;
    }
    return ScaleCondition.normal;
  }
}
