import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItemController: StatusItemController?
    var bluetoothManager: BluetoothManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)

        // Initialize Bluetooth manager
        bluetoothManager = BluetoothManager()

        // Initialize status item controller
        statusItemController = StatusItemController(bluetoothManager: bluetoothManager!)
    }

    func applicationWillTerminate(_ notification: Notification) {
        bluetoothManager?.disconnect()
    }
}
