import SwiftUI

/// Moon Code 标题下的横排设备入口；顺序与账号面板里的设备列表一致。
struct DeviceStrip: View {
    static let scrollAccessibilityIdentifier = "sidebar-device-strip"

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(app.devices) { device in
                    deviceButton(device)
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 38)
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 56)
            }
        }
        .accessibilityIdentifier(Self.scrollAccessibilityIdentifier)
        .padding(.trailing, 20)
    }

    private func deviceButton(_ device: RemoteDevice) -> some View {
        let isCurrent = device.deviceID == app.endpoint?.deviceID
        return Button {
            Task { await app.select(device) }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(device.isOnline ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(device.shortName)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(device.isOnline ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                isCurrent ? Palette.kimi.opacity(0.12) : Color(.secondarySystemBackground),
                in: .capsule
            )
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!device.isOnline)
        .accessibilityLabel("\(device.shortName)，\(device.isOnline ? "在线" : "离线")")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
