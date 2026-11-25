## Unreleased

- Add `DahuaScaleProtocol` for Shanghai Dahua price-computing scales that stream multi-field frames such as `" 0065    000     000\r"`.

## 0.2.0

- Add TCP scale connections for network scales.
- Add Windows, macOS, and Linux serial connections with device discovery.
- Add Android USB-UART connections with permission handling through the platform plugin.
- Support CDC, CH340, CP210x, FTDI, and PL2303 Android USB serial adapters.

## 0.1.0

- Add exact decimal scale weight values without floating-point loss.
- Add streaming generic ASCII scale protocol parsing.
- Add stable, unstable, gross, net, tare, overload, and underload states.
- Add transport and session interfaces for future serial, USB, Bluetooth, and vendor SDK adapters.
