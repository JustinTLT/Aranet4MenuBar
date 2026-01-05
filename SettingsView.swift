import SwiftUI

struct SettingsView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and test button
            HStack {
                Text("Alert Sound")
                    .font(.headline)
                Spacer()
                Button("Test Alert") {
                    bluetoothManager.sendTestNotification()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Settings content
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AlertSoundType.allCases, id: \.self) { type in
                    Button(action: {
                        bluetoothManager.alertSoundType = type
                    }) {
                        HStack {
                            Text(type.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if type == bluetoothManager.alertSoundType {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(
                        type == bluetoothManager.alertSoundType
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 12)

            Text("Plays when CO2 reaches 1200 ppm or higher")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .frame(width: 400, height: 235)
    }
}
