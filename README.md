# kservice_scale

`kservice_scale` 是独立于打印机的电子秤协议核心。它负责解析称重报文和编排连接会话，不绑定具体串口、USB、蓝牙或厂家 SDK。

## 当前能力

- 处理串口/USB 常见的分块、粘包和 CR/LF 分帧
- 解析稳定、动态、毛重、净重和去皮状态
- 解析正负重量及 kg、g、mg、lb、oz 单位
- 识别过载和欠载
- 使用十进制定点值保存重量，避免先转换成 `double` 造成精度损失
- 提供 `ScaleTransport`，后续厂家 SDK 或平台连接只需实现该接口
- 控制命令默认为空，只有拿到厂家协议后才允许配置置零、去皮等指令

## 通用 ASCII 报文

```dart
import 'dart:convert';
import 'package:kservice_scale/kservice_scale.dart';

final protocol = GenericAsciiScaleProtocol();

final events = protocol.addBytes(
  ascii.encode('ST,GS, 1.250kg\r\nUS,NT,-0.030 kg\r\n'),
);

for (final event in events) {
  final reading = event.reading;
  if (reading != null) {
    print(reading.weight);     // 1.250 kg
    print(reading.isStable);   // true
    print(reading.ready);      // true only for explicitly stable values
  } else {
    print(event.error);
  }
}
```

同一帧出现多个数字时，通用解析器会返回 `ambiguousWeight`，不会猜测哪个数字是重量。厂家协议包含价格、皮重或校验数字时，应实现单独的 `ScaleProtocol`。

无单位报文默认会返回 `missingUnit`，防止把克误当成千克。只有确认设备固定单位后才能显式开启：

```dart
final protocol = GenericAsciiScaleProtocol(
  allowUnitless: true,
  defaultUnit: ScaleUnit.gram,
);
```

## 精确重量

`ScaleWeight` 保存原始十进制位数：

```dart
final weight = ScaleWeight.parse('1.250', ScaleUnit.kilogram);

print(weight.unscaledValue);  // 1250
print(weight.fractionDigits); // 3
print(weight.decimalValue);   // 1.250
```

业务结算应使用 `unscaledValue + fractionDigits` 或十进制库计算。`approximateValue` 只适合 UI 展示，不建议用于金额计算。

## 接入传输层

串口、USB、蓝牙和厂家 SDK 都实现同一个接口：

```dart
abstract interface class ScaleTransport {
  String get id;
  bool get isOpen;
  Stream<List<int>> get bytes;
  Future<void> open();
  Future<void> write(List<int> bytes);
  Future<void> close();
}
```

然后交给 `ScaleSession`：

```dart
final session = ScaleSession(
  transport: vendorTransport,
  protocol: GenericAsciiScaleProtocol(),
);

session.readings.listen((reading) {
  if (reading.ready) {
    print('可结算重量: ${reading.weight}');
  }
});

await session.connect();
```

## 厂家命令

置零、去皮和主动读重没有行业统一指令。拿到厂家协议后再显式配置：

```dart
final protocol = GenericAsciiScaleProtocol(
  commands: ScaleCommandSet(
    requestWeight: ascii.encode('W\r\n'),
    zero: ascii.encode('Z\r\n'),
    tare: ascii.encode('T\r\n'),
  ),
);
```

上面的 `W/Z/T` 仅展示配置方法，不代表任何真实电子秤协议，不应直接用于设备。

## 边界

当前包是通用协议核心，不会自行打开串口或申请 USB/蓝牙权限。下一阶段应根据实际设备选择：

- 通用 USB 转串口适配包
- Android USB Host 适配包
- 蓝牙串口适配包
- 厂家 SDK 专用适配包，例如 `kservice_scale_<vendor>`
