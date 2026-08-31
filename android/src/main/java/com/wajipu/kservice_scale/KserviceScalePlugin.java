package com.wajipu.kservice_scale;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import com.hoho.android.usbserial.driver.UsbSerialDriver;
import com.hoho.android.usbserial.driver.UsbSerialPort;
import com.hoho.android.usbserial.driver.UsbSerialProber;
import com.hoho.android.usbserial.util.SerialInputOutputManager;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class KserviceScalePlugin
        implements FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private static final String USB_PERMISSION_ACTION =
            "com.wajipu.kservice_scale.USB_PERMISSION";
    private static final long USB_PERMISSION_TIMEOUT_MS = 30000L;

    private final Map<String, UsbSession> sessions = new ConcurrentHashMap<>();
    private final Map<Integer, PendingOpen> pendingOpens = new HashMap<>();

    private Context context;
    private Handler mainHandler;
    private ExecutorService executor;
    private MethodChannel methodChannel;
    private EventChannel eventChannel;
    private EventChannel.EventSink eventSink;
    private UsbManager usbManager;
    private BroadcastReceiver permissionReceiver;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        mainHandler = new Handler(Looper.getMainLooper());
        executor = Executors.newFixedThreadPool(4);
        usbManager = (UsbManager) context.getSystemService(Context.USB_SERVICE);
        methodChannel = new MethodChannel(binding.getBinaryMessenger(), "kservice_scale");
        methodChannel.setMethodCallHandler(this);
        eventChannel =
                new EventChannel(
                        binding.getBinaryMessenger(), "kservice_scale/usb_serial_events");
        eventChannel.setStreamHandler(this);
        registerPermissionReceiver();
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        for (PendingOpen pending : new ArrayList<>(pendingOpens.values())) {
            pending.cancelTimeout();
            pending.result.error("plugin_detached", "Scale plugin was detached", null);
        }
        pendingOpens.clear();
        for (UsbSession session : new ArrayList<>(sessions.values())) {
            session.close();
        }
        sessions.clear();
        if (permissionReceiver != null) {
            try {
                context.unregisterReceiver(permissionReceiver);
            } catch (RuntimeException ignored) {
            }
            permissionReceiver = null;
        }
        if (executor != null) {
            executor.shutdownNow();
        }
        methodChannel.setMethodCallHandler(null);
        eventChannel.setStreamHandler(null);
        eventSink = null;
        context = null;
        mainHandler = null;
        executor = null;
        usbManager = null;
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        eventSink = events;
    }

    @Override
    public void onCancel(Object arguments) {
        eventSink = null;
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (usbManager == null || executor == null || mainHandler == null) {
            result.error("plugin_not_ready", "Scale plugin is not initialized", null);
            return;
        }
        switch (call.method) {
            case "listUsbSerialDevices":
                result.success(listDevices());
                break;
            case "openUsbSerial":
                openUsbSerial(call, result);
                break;
            case "writeUsbSerial":
                writeUsbSerial(call, result);
                break;
            case "closeUsbSerial":
                closeUsbSerial(call, result);
                break;
            default:
                result.notImplemented();
        }
    }

    private List<Map<String, Object>> listDevices() {
        List<Map<String, Object>> result = new ArrayList<>();
        for (UsbSerialDriver driver :
                UsbSerialProber.getDefaultProber().findAllDrivers(usbManager)) {
            UsbDevice device = driver.getDevice();
            List<UsbSerialPort> ports = driver.getPorts();
            for (int portIndex = 0; portIndex < ports.size(); portIndex += 1) {
                Map<String, Object> value = new HashMap<>();
                value.put("deviceName", device.getDeviceName());
                value.put("deviceId", device.getDeviceId());
                value.put("portIndex", portIndex);
                value.put("vendorId", device.getVendorId());
                value.put("productId", device.getProductId());
                value.put("driver", driver.getClass().getSimpleName());
                value.put("interfaceCount", device.getInterfaceCount());
                putIfNotNull(value, "productName", safeUsbString(device::getProductName));
                putIfNotNull(value, "manufacturer", safeUsbString(device::getManufacturerName));
                putIfNotNull(value, "serialNumber", safeUsbString(device::getSerialNumber));
                result.add(value);
            }
        }
        return result;
    }

    private void openUsbSerial(MethodCall call, MethodChannel.Result result) {
        String connectionId = call.argument("connectionId");
        Number deviceId = call.argument("deviceId");
        Number vendorId = call.argument("vendorId");
        Number productId = call.argument("productId");
        Number portIndex = call.argument("portIndex");
        if (connectionId == null
                || connectionId.isEmpty()
                || deviceId == null
                || vendorId == null
                || productId == null
                || portIndex == null) {
            result.error("invalid_argument", "USB serial target is incomplete", null);
            return;
        }
        if (sessions.containsKey(connectionId)) {
            result.error("invalid_argument", "Connection ID is already open", null);
            return;
        }

        DriverMatch match =
                findDriver(deviceId.intValue(), vendorId.intValue(), productId.intValue());
        if (match.ambiguous) {
            result.error(
                    "device_ambiguous",
                    "Multiple USB serial devices have the same VID/PID; scan again",
                    null);
            return;
        }
        if (match.driver == null) {
            result.error("device_not_found", "USB serial scale is no longer connected", null);
            return;
        }
        int index = portIndex.intValue();
        if (index < 0 || index >= match.driver.getPorts().size()) {
            result.error("invalid_argument", "USB serial port index is invalid", null);
            return;
        }

        PendingOpen pending = new PendingOpen(connectionId, match.driver, index, call, result);
        UsbDevice device = match.driver.getDevice();
        if (usbManager.hasPermission(device)) {
            openPending(pending);
            return;
        }
        if (pendingOpens.putIfAbsent(device.getDeviceId(), pending) != null) {
            result.error("operation_in_progress", "USB permission request is already active", null);
            return;
        }
        pending.startTimeout(device.getDeviceId());
        Intent intent = new Intent(USB_PERMISSION_ACTION).setPackage(context.getPackageName());
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent permissionIntent =
                PendingIntent.getBroadcast(context, device.getDeviceId(), intent, flags);
        usbManager.requestPermission(device, permissionIntent);
    }

    private void openPending(PendingOpen pending) {
        ExecutorService currentExecutor = executor;
        Handler handler = mainHandler;
        if (currentExecutor == null || handler == null) {
            pending.result.error("plugin_not_ready", "Scale plugin is not initialized", null);
            return;
        }
        currentExecutor.execute(
                () -> {
                    UsbDeviceConnection connection = null;
                    UsbSerialPort port = null;
                    try {
                        UsbDevice device = pending.driver.getDevice();
                        connection = usbManager.openDevice(device);
                        if (connection == null) {
                            throw new IllegalStateException("UsbManager.openDevice returned null");
                        }
                        port = pending.driver.getPorts().get(pending.portIndex);
                        port.open(connection);
                        port.setParameters(
                                intArgument(pending.call, "baudRate", 9600),
                                intArgument(pending.call, "dataBits", 8),
                                intArgument(pending.call, "stopBits", 1),
                                parityArgument(pending.call));
                        UsbSerialPort.FlowControl flowControl = flowControlArgument(pending.call);
                        if (!port.getSupportedFlowControl().contains(flowControl)) {
                            throw new UnsupportedOperationException(
                                    "USB serial driver does not support " + flowControl);
                        }
                        port.setFlowControl(flowControl);
                        if (flowControl == UsbSerialPort.FlowControl.NONE) {
                            setControlLine(port, true, boolArgument(pending.call, "dtr"));
                            setControlLine(port, false, boolArgument(pending.call, "rts"));
                        }

                        UsbSession session = new UsbSession(pending.connectionId, port, connection);
                        sessions.put(pending.connectionId, session);
                        handler.post(
                                () -> {
                                    pending.result.success(null);
                                    session.start();
                                });
                    } catch (Exception error) {
                        closeQuietly(port, connection);
                        String message = messageFor(error);
                        handler.post(
                                () -> pending.result.error("open_failed", message, null));
                    }
                });
    }

    private void writeUsbSerial(MethodCall call, MethodChannel.Result result) {
        String connectionId = call.argument("connectionId");
        byte[] data = call.argument("data");
        UsbSession session = sessions.get(connectionId);
        if (session == null) {
            result.error("write_failed", "USB serial scale connection is not open", null);
            return;
        }
        if (data == null || data.length == 0) {
            result.error("invalid_argument", "USB serial write data is empty", null);
            return;
        }
        int timeoutMs = intArgument(call, "timeoutMs", 2000);
        executor.execute(
                () -> {
                    try {
                        session.port.write(data, timeoutMs);
                        mainHandler.post(() -> result.success(null));
                    } catch (Exception error) {
                        String message = messageFor(error);
                        mainHandler.post(
                                () -> result.error("write_failed", message, null));
                    }
                });
    }

    private void closeUsbSerial(MethodCall call, MethodChannel.Result result) {
        String connectionId = call.argument("connectionId");
        PendingOpen pending = null;
        Integer pendingDeviceId = null;
        for (Map.Entry<Integer, PendingOpen> entry : pendingOpens.entrySet()) {
            if (entry.getValue().connectionId.equals(connectionId)) {
                pendingDeviceId = entry.getKey();
                pending = entry.getValue();
                break;
            }
        }
        if (pendingDeviceId != null) {
            pendingOpens.remove(pendingDeviceId);
            pending.cancelTimeout();
            pending.result.error("open_cancelled", "USB serial open was cancelled", null);
        }
        UsbSession session = sessions.remove(connectionId);
        if (session != null) {
            session.close();
        }
        result.success(null);
    }

    private DriverMatch findDriver(int deviceId, int vendorId, int productId) {
        List<UsbSerialDriver> matches = new ArrayList<>();
        for (UsbSerialDriver driver :
                UsbSerialProber.getDefaultProber().findAllDrivers(usbManager)) {
            UsbDevice device = driver.getDevice();
            if (device.getDeviceId() == deviceId
                    && device.getVendorId() == vendorId
                    && device.getProductId() == productId) {
                return new DriverMatch(driver, false);
            }
            if (device.getVendorId() == vendorId && device.getProductId() == productId) {
                matches.add(driver);
            }
        }
        if (matches.size() == 1) {
            return new DriverMatch(matches.get(0), false);
        }
        return new DriverMatch(null, matches.size() > 1);
    }

    private void registerPermissionReceiver() {
        permissionReceiver =
                new BroadcastReceiver() {
                    @Override
                    public void onReceive(Context receiverContext, Intent intent) {
                        if (!USB_PERMISSION_ACTION.equals(intent.getAction())) {
                            return;
                        }
                        UsbDevice device = usbDeviceExtra(intent);
                        if (device == null) {
                            return;
                        }
                        PendingOpen pending = pendingOpens.remove(device.getDeviceId());
                        if (pending == null) {
                            return;
                        }
                        pending.cancelTimeout();
                        boolean granted =
                                intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false);
                        if (granted) {
                            openPending(pending);
                        } else {
                            pending.result.error(
                                    "usb_permission_denied",
                                    "USB serial scale permission was denied",
                                    null);
                        }
                    }
                };
        IntentFilter filter = new IntentFilter(USB_PERMISSION_ACTION);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            context.registerReceiver(permissionReceiver, filter);
        }
    }

    @SuppressWarnings("deprecation")
    private static UsbDevice usbDeviceExtra(Intent intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice.class);
        }
        return intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
    }

    private void emit(Map<String, Object> event) {
        Handler handler = mainHandler;
        if (handler == null) {
            return;
        }
        handler.post(
                () -> {
                    EventChannel.EventSink sink = eventSink;
                    if (sink != null) {
                        sink.success(event);
                    }
                });
    }

    private final class UsbSession {
        final String connectionId;
        final UsbSerialPort port;
        final UsbDeviceConnection connection;
        final SerialInputOutputManager ioManager;

        UsbSession(String connectionId, UsbSerialPort port, UsbDeviceConnection connection) {
            this.connectionId = connectionId;
            this.port = port;
            this.connection = connection;
            this.ioManager =
                    new SerialInputOutputManager(
                            port,
                            new SerialInputOutputManager.Listener() {
                                @Override
                                public void onNewData(byte[] data) {
                                    Map<String, Object> event = new HashMap<>();
                                    event.put("connectionId", connectionId);
                                    event.put("data", data);
                                    emit(event);
                                }

                                @Override
                                public void onRunError(Exception error) {
                                    sessions.remove(connectionId);
                                    Map<String, Object> event = new HashMap<>();
                                    event.put("connectionId", connectionId);
                                    event.put("error", messageFor(error));
                                    event.put("closed", true);
                                    emit(event);
                                    close();
                                }
                            });
        }

        void start() {
            ioManager.start();
        }

        void close() {
            ioManager.stop();
            closeQuietly(port, connection);
        }
    }

    private final class PendingOpen {
        final String connectionId;
        final UsbSerialDriver driver;
        final int portIndex;
        final MethodCall call;
        final MethodChannel.Result result;
        Runnable timeout;

        PendingOpen(
                String connectionId,
                UsbSerialDriver driver,
                int portIndex,
                MethodCall call,
                MethodChannel.Result result) {
            this.connectionId = connectionId;
            this.driver = driver;
            this.portIndex = portIndex;
            this.call = call;
            this.result = result;
        }

        void startTimeout(int deviceId) {
            timeout =
                    () -> {
                        if (pendingOpens.remove(deviceId) == this) {
                            result.error(
                                    "usb_permission_timeout",
                                    "USB serial permission request timed out",
                                    null);
                        }
                    };
            mainHandler.postDelayed(timeout, USB_PERMISSION_TIMEOUT_MS);
        }

        void cancelTimeout() {
            if (timeout != null && mainHandler != null) {
                mainHandler.removeCallbacks(timeout);
            }
            timeout = null;
        }
    }

    private static final class DriverMatch {
        final UsbSerialDriver driver;
        final boolean ambiguous;

        DriverMatch(UsbSerialDriver driver, boolean ambiguous) {
            this.driver = driver;
            this.ambiguous = ambiguous;
        }
    }

    private static int intArgument(MethodCall call, String key, int fallback) {
        Number value = call.argument(key);
        return value == null ? fallback : value.intValue();
    }

    private static boolean boolArgument(MethodCall call, String key) {
        Boolean value = call.argument(key);
        return value != null && value;
    }

    private static int parityArgument(MethodCall call) {
        return switch (intArgument(call, "parity", 0)) {
            case 1 -> UsbSerialPort.PARITY_ODD;
            case 2 -> UsbSerialPort.PARITY_EVEN;
            case 3 -> UsbSerialPort.PARITY_MARK;
            case 4 -> UsbSerialPort.PARITY_SPACE;
            default -> UsbSerialPort.PARITY_NONE;
        };
    }

    private static UsbSerialPort.FlowControl flowControlArgument(MethodCall call) {
        return switch (intArgument(call, "flowControl", 0)) {
            case 1 -> UsbSerialPort.FlowControl.XON_XOFF;
            case 2 -> UsbSerialPort.FlowControl.RTS_CTS;
            case 3 -> UsbSerialPort.FlowControl.DTR_DSR;
            default -> UsbSerialPort.FlowControl.NONE;
        };
    }

    private static void setControlLine(UsbSerialPort port, boolean dtr, boolean value)
            throws Exception {
        try {
            if (dtr) {
                port.setDTR(value);
            } else {
                port.setRTS(value);
            }
        } catch (UnsupportedOperationException error) {
            if (value) {
                throw error;
            }
        }
    }

    private static void closeQuietly(UsbSerialPort port, UsbDeviceConnection connection) {
        if (port != null) {
            try {
                port.close();
            } catch (Exception ignored) {
            }
        }
        if (connection != null) {
            connection.close();
        }
    }

    private static void putIfNotNull(Map<String, Object> map, String key, String value) {
        if (value != null && !value.isEmpty()) {
            map.put(key, value);
        }
    }

    private static String safeUsbString(UsbStringReader reader) {
        try {
            return reader.read();
        } catch (RuntimeException ignored) {
            return null;
        }
    }

    private static String messageFor(Exception error) {
        String message = error.getMessage();
        return message == null || message.isEmpty()
                ? error.getClass().getSimpleName()
                : message;
    }

    private interface UsbStringReader {
        String read();
    }
}
