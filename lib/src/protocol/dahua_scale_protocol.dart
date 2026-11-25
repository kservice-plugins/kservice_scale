import 'dart:convert';

import '../model/scale_reading.dart';
import '../model/scale_weight.dart';
import 'scale_protocol.dart';

/// 上海大华「计价秤」连续输出协议。
///
/// 典型帧（9600 8N1，以 CR 结尾）：
/// `" 0065    000     000\r"`
///
/// 字段以空格分隔，依次为：净重 / 单价 / 金额；首字段为重量。金额或单价为
/// 0 时同样以数字形式出现，因此通用 ASCII 解析器会因为「一帧多个数字」返回
/// `ambiguousWeight`，且缺少单位会返回 `missingUnit`。本协议只取
/// [weightFieldIndex] 指定的数字作为净重，忽略其余字段。
///
/// 帧本身不含「稳定/不稳」标志，默认按稳定处理（[assumeStable] = true），
/// 使上层 [ScaleReading.ready] 能直接用于结算；若你的设备需要判稳，可自行
/// 扩展解析逻辑。
///
/// 重量默认按「帧内整数即克、以 kg 三位小数表示」处理（`0065` → `0.065 kg`）。
/// 若设备的整数含义不同（例如直接以克输出整数），把 [unit] 设为
/// [ScaleUnit.gram] 并把 [fractionDigits] 设为 0。
class DahuaScaleProtocol implements ScaleProtocol {
  DahuaScaleProtocol({
    this.unit = ScaleUnit.kilogram,
    this.fractionDigits = 3,
    this.weightFieldIndex = 0,
    this.assumeStable = true,
    this.maxFrameBytes = 256,
    this.commands = const ScaleCommandSet(),
    List<int> terminators = const [0x0d, 0x0a],
  }) : _terminators = Set<int>.unmodifiable(terminators) {
    if (fractionDigits < 0) {
      throw ArgumentError.value(
        fractionDigits,
        'fractionDigits',
        'must not be negative',
      );
    }
    if (weightFieldIndex < 0) {
      throw ArgumentError.value(
        weightFieldIndex,
        'weightFieldIndex',
        'must not be negative',
      );
    }
    if (maxFrameBytes < 16 || maxFrameBytes > 4096) {
      throw ArgumentError.value(
        maxFrameBytes,
        'maxFrameBytes',
        'must be between 16 and 4096',
      );
    }
    if (_terminators.isEmpty) {
      throw ArgumentError.value(
        terminators,
        'terminators',
        'must not be empty',
      );
    }
  }

  /// 重量单位。
  final ScaleUnit unit;

  /// 当帧内重量没有小数点时，隐含的小数位数。
  final int fractionDigits;

  /// 取第几个数字作为重量（0 表示第一个，即净重）。
  final int weightFieldIndex;

  /// 帧内无稳定性标志时，是否按「稳定」上报。
  final bool assumeStable;

  final int maxFrameBytes;
  final Set<int> _terminators;
  final List<int> _buffer = [];
  bool _discardingOversizedFrame = false;

  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _numberToken = RegExp(r'^[+-]?\d+(?:[.,]\d+)?$');

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
    if (rawFrame.isEmpty) {
      return _error(
        ScaleProtocolErrorCode.missingWeight,
        'Scale frame is empty',
        rawFrame,
      );
    }

    final tokens =
        rawFrame.split(_whitespace).where((token) => token.isNotEmpty).toList();
    final numbers = tokens.where(_numberToken.hasMatch).toList();
    if (numbers.isEmpty) {
      return _error(
        ScaleProtocolErrorCode.missingWeight,
        'Scale frame does not contain a weight',
        rawFrame,
      );
    }

    final index = weightFieldIndex < numbers.length
        ? weightFieldIndex
        : numbers.length - 1;
    final token = numbers[index].replaceAll(',', '.');

    final ScaleWeight weight;
    try {
      if (token.contains('.')) {
        weight = ScaleWeight.parse(token, unit);
      } else {
        weight = ScaleWeight(
          unscaledValue: BigInt.parse(token),
          fractionDigits: fractionDigits,
          unit: unit,
        );
      }
    } on FormatException {
      return _error(
        ScaleProtocolErrorCode.invalidWeight,
        'Scale frame contains an invalid weight',
        rawFrame,
      );
    }

    return ScaleProtocolEvent.reading(
      ScaleReading(
        weight: weight,
        rawFrame: rawFrame,
        receivedAt: receivedAt ?? DateTime.now(),
        stability:
            assumeStable ? ScaleStability.stable : ScaleStability.unknown,
        mode: ScaleWeightMode.net,
        condition: ScaleCondition.normal,
      ),
    );
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
}
