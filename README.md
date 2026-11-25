# kservice_scale

`kservice_scale` 是独立于打印机的电子秤连接与协议包。它提供通用 TCP、桌面串口和 Android USB-UART 连接，同时保留可插拔接口供后续厂家 SDK 使用。

Flutter 应用使用 `package:kservice_scale/kservice_scale.dart`；只需要协议解析或 TCP 且不依赖 Flutter 平台插件时，可以使用 `package:kservice_scale/kservice_scale_core.dart`。

## 当前能力

- 处理串口/USB 常见的分块、粘包和 CR/LF 分帧
- 解析稳定、动态、毛重、净重和去皮状态
- 解析正负重量及 kg、g、mg、lb、oz 单位
- 识别过载和欠载
- 使用十进制定点值保存重量，避免先转换成 `double` 造成精度损失
- 提供 `ScaleTransport`，后续厂家 SDK 或平台连接只需实现该接口
- 控制命令默认为空，只有拿到厂家协议后才允许配置置零、去皮等指令

## 通用连接

| 连接 | Android | Windows | macOS | Linux |
|------|---------|---------|-------|-------|
| TCP 网络秤 | ✅ | ✅ | ✅ | ✅ |
| 系统串口 / USB 虚拟 COM | - | ✅ | ✅ | ✅ |
| USB-UART OTG | ✅ | - | - | - |

Android USB-UART 支持 CDC、CH340、CP210x、FTDI 和 PL2303。原生 USB HID、USB Bulk 以及厂家私有设备不属于通用串口，后续通过厂家 SDK 适配。

### TCP 网络秤

```dart
final transport = TcpScaleTransport(
  host: '192.168.1.80',
  port: 4001,
);

final session = ScaleSession(
  transport: transport,
  protocol: GenericAsciiScaleProtocol(),
);

await session.connect();
```

### Windows / macOS / Linux 串口

先枚举端口，再使用设备手册规定的串口参数：

```dart
final devices = listSerialScaleDevices();
for (final device in devices) {
  print('${device.displayName} ${device.type}');
}

final transport = SerialScaleTransport(
  portName: devices.first.name, // COM3 或 /dev/ttyUSB0
  settings: const ScaleSerialSettings(
    baudRate: 9600,
    dataBits: 8,
    stopBits: 1,
    parity: ScaleSerialParity.none,
  ),
);
```

Linux 需要为串口设备配置 udev 权限；macOS 沙盒应用需要相应设备权限。桌面串口底层使用 `libserialport`，宿主必须安装或随应用捆绑对应动态库，也可以通过 `LIBSERIALPORT_PATH` 指定路径。发布应用时需要遵守其 LGPL 许可证要求。当前没有依赖 `flutter_libserialport`，因为其 Android Gradle 配置仍使用已移除的 `jcenter()`，会导致新版 Flutter 的 APK 构建失败。

### Android USB-UART

```dart
final devices = await listAndroidUsbSerialDevices();
final transport = AndroidUsbSerialScaleTransport(
  device: devices.first,
  settings: const ScaleSerialSettings(baudRate: 9600),
);

final session = ScaleSession(
  transport: transport,
  protocol: GenericAsciiScaleProtocol(),
);

await session.connect(); // 必要时弹出 Android USB 授权
```

必须使用枚举结果中的设备对象，不能只按 VID/PID 随意选择；多台相同型号设备无法唯一确认时会返回 `deviceAmbiguous`。

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

## 上海大华计价秤（连续输出）

部分上海大华计价秤在 `9600 8N1` 下连续输出形如下面的帧（净重 / 单价 / 金额）：

```text
" 0065    000     000\r"
```

该帧包含多个数字且没有单位，通用解析器会返回 `ambiguousWeight` / `missingUnit`。
这类设备请使用专用的 `DahuaScaleProtocol`，它只取指定字段作为净重并忽略单价与金额：

```dart
final protocol = DahuaScaleProtocol(
  // 默认：帧内整数按克解释，以 kg 三位小数表示（0065 -> 0.065 kg）。
  unit: ScaleUnit.kilogram,
  fractionDigits: 3,
);

final session = ScaleSession(
  transport: transport, // 例如 AndroidUsbSerialScaleTransport
  protocol: protocol,
);

session.readings.listen((reading) {
  if (reading.ready) {
    print(reading.weight); // 0.065 kg
  }
});
```

若设备的整数表示克（`0065` -> `65 g`），改为 `unit: ScaleUnit.gram, fractionDigits: 0`。
字段顺序不同可调整 `weightFieldIndex`（默认 `0`，即净重）；帧不含稳定性标志时默认按稳定上报，
需要判稳可设 `assumeStable: false`。

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

当前包已覆盖通用 TCP、桌面串口和 Android USB-UART。下一阶段根据实际设备选择：

- 蓝牙串口适配包
- 原生 USB HID / Bulk 适配包
- 厂家 SDK 专用适配包，例如 `kservice_scale_<vendor>`
