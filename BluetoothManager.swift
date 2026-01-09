import Foundation
import CoreBluetooth
import Combine
import UserNotifications
import AppKit

class BluetoothManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var currentReading: Aranet4Reading?
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private var centralManager: CBCentralManager!
    private var aranet4Peripheral: CBPeripheral?
    private var currentReadingsCharacteristic: CBCharacteristic?
    private var refreshTimer: Timer?
    private var scanTimeoutTimer: Timer?
    private var retryTimer: Timer?
    private var autoRefreshInterval: TimeInterval = 300 // 5 minutes
    private var scanTimeout: TimeInterval = 30 // 30 seconds
    private var retryInterval: TimeInterval = 300 // 5 minutes - retry scanning when device not found

    // Alert settings
    private var co2AlertThreshold: Int = 1200 // ppm
    private var hasAlertedForHighCO2: Bool = false
    private var gentleAlertSound: NSSound?
    private var urgentAlertSound: NSSound?

    @Published var alertSoundType: AlertSoundType = .gentle {
        didSet {
            UserDefaults.standard.set(alertSoundType.rawValue, forKey: "alertSoundType")
        }
    }

    // MARK: - Initialization

    override init() {
        super.init()

        // Load saved alert sound preference
        if let savedType = UserDefaults.standard.string(forKey: "alertSoundType"),
           let type = AlertSoundType(rawValue: savedType) {
            alertSoundType = type
        }

        centralManager = CBCentralManager(delegate: self, queue: nil)
        requestNotificationPermissions()
        setupAlertSounds()
    }

    private func setupAlertSounds() {
        // Load gentle alert sound
        if let gentlePath = Bundle.main.path(forResource: "air_quality_alert", ofType: "aiff") {
            gentleAlertSound = NSSound(contentsOfFile: gentlePath, byReference: false)
        }

        // Load urgent/fire alarm sound
        if let urgentPath = Bundle.main.path(forResource: "fire_alarm", ofType: "aiff") {
            urgentAlertSound = NSSound(contentsOfFile: urgentPath, byReference: false)
        }
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Permission requested
        }
    }

    private func sendHighCO2Alert(co2: Int) {
        let content = UNMutableNotificationContent()
        content.title = "High CO2 Alert"
        content.body = "CO2 level is \(co2) ppm. Consider opening a window or improving ventilation."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "highCO2", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)

        // Play audio alarm - 3 beeps with pauses
        playAlarmSound()
    }

    private func playAlarmSound() {
        switch alertSoundType {
        case .off:
            // No sound
            return

        case .gentle:
            // Play gentle sound 2 times
            guard let sound = gentleAlertSound else { return }
            for i in 0..<2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.6) {
                    sound.play()
                }
            }

        case .urgent:
            // Play fire alarm once (it's already 5 seconds long)
            urgentAlertSound?.play()
        }
    }

    func sendTestNotification() {
        // Check notification authorization status first
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    // Permission granted, send notification
                    let content = UNMutableNotificationContent()
                    content.title = "Test Notification"
                    content.body = "Notifications and alarm sound are working! You'll be alerted when CO2 reaches 1200 ppm."
                    content.sound = .default

                    let request = UNNotificationRequest(identifier: "test", content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)

                    // Also play the alarm sound so user can hear it
                    self.playAlarmSound()

                case .denied:
                    // Permission denied - show alert
                    let alert = NSAlert()
                    alert.messageText = "Notifications Disabled"
                    alert.informativeText = "Please enable notifications for Aranet4 in System Settings → Notifications to receive CO2 alerts."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Cancel")

                    if alert.runModal() == .alertFirstButtonReturn {
                        // Open System Settings to Notifications
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                case .notDetermined:
                    // Permission not yet requested - request it now
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        if granted {
                            // Send test notification after granting
                            self.sendTestNotification()
                        }
                    }

                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Public Methods

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            errorMessage = "Bluetooth is not available"
            return
        }

        connectionStatus = .scanning
        errorMessage = nil

        let serviceUUIDs = [
            CBUUID(string: Aranet4UUIDs.serviceUUID),
            CBUUID(string: Aranet4UUIDs.serviceUUIDNew)
        ]

        centralManager.scanForPeripherals(
            withServices: serviceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Start scan timeout timer
        startScanTimeoutTimer()
    }

    func stopScanning() {
        centralManager.stopScan()
        stopScanTimeoutTimer()
    }

    func refreshReadings() {
        guard let characteristic = currentReadingsCharacteristic,
              let peripheral = aranet4Peripheral else {
            errorMessage = "Not connected to device"
            return
        }

        peripheral.readValue(for: characteristic)
    }

    func disconnect() {
        if let peripheral = aranet4Peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        stopRefreshTimer()
        stopRetryTimer()
    }

    // MARK: - Private Methods

    private func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: autoRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshReadings()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startScanTimeoutTimer() {
        stopScanTimeoutTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: self.scanTimeout, repeats: false) { [weak self] _ in
                self?.handleScanTimeout()
            }
        }
    }

    private func stopScanTimeoutTimer() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
    }

    private func handleScanTimeout() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Stop scanning and update status
            self.centralManager.stopScan()
            self.connectionStatus = .notFound
            self.errorMessage = nil  // Clear error message, status indicator is enough
            // Start periodic retry timer
            self.startRetryTimer()
        }
    }

    private func startRetryTimer() {
        stopRetryTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.retryTimer = Timer.scheduledTimer(withTimeInterval: self.retryInterval, repeats: true) { [weak self] _ in
                self?.startScanning()
            }
        }
    }

    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            connectionStatus = .disconnected
            errorMessage = "Bluetooth is powered off"
        case .unauthorized:
            connectionStatus = .disconnected
            errorMessage = "Bluetooth permission denied"
        case .unsupported:
            connectionStatus = .disconnected
            errorMessage = "Bluetooth not supported"
        default:
            connectionStatus = .disconnected
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Auto-connect to first Aranet4 found
        aranet4Peripheral = peripheral
        aranet4Peripheral?.delegate = self
        connectionStatus = .connecting
        stopScanning()  // This also stops the timeout timer

        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionStatus = .connected
        errorMessage = nil
        stopRetryTimer()  // Stop retry timer since we're connected

        // Discover services
        let serviceUUIDs = [
            CBUUID(string: Aranet4UUIDs.serviceUUID),
            CBUUID(string: Aranet4UUIDs.serviceUUIDNew)
        ]
        peripheral.discoverServices(serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = .notFound
        errorMessage = nil
        aranet4Peripheral = nil
        // Start periodic retry
        startRetryTimer()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionStatus = .notFound
        errorMessage = nil
        aranet4Peripheral = nil
        currentReadingsCharacteristic = nil
        stopRefreshTimer()
        // Keep last reading available, start periodic retry
        startRetryTimer()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        guard let services = peripheral.services else { return }

        for service in services {
            let characteristicUUID = CBUUID(string: Aranet4UUIDs.currentReadingsUUID)
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            // Try both current readings characteristics
            let currentUUID = CBUUID(string: Aranet4UUIDs.currentReadingsUUID)
            let detailedUUID = CBUUID(string: Aranet4UUIDs.currentReadingsDetailedUUID)

            if characteristic.uuid == currentUUID || characteristic.uuid == detailedUUID {
                currentReadingsCharacteristic = characteristic
                // Read initial value
                peripheral.readValue(for: characteristic)
                // Start auto-refresh timer
                startRefreshTimer()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            errorMessage = "Failed to read sensor data"
            return
        }

        guard let data = characteristic.value else { return }

        // Decode the reading
        if let reading = Aranet4Reading.decode(from: data) {
            DispatchQueue.main.async {
                self.currentReading = reading
                self.lastUpdated = Date()
                self.errorMessage = nil

                // Check for high CO2 and send alert
                self.checkCO2Level(reading.co2)
            }
        } else {
            errorMessage = "Failed to decode sensor data"
        }
    }

    private func checkCO2Level(_ co2: Int) {
        if co2 >= co2AlertThreshold {
            if !hasAlertedForHighCO2 {
                sendHighCO2Alert(co2: co2)
                hasAlertedForHighCO2 = true
            }
        } else {
            // Reset alert flag when CO2 drops below threshold
            hasAlertedForHighCO2 = false
        }
    }
}
