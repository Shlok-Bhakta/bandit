import ActivityKit
import SwiftUI
import WidgetKit

/// NP Dongle's Live Activities. The app starts and updates them while it runs (an update keeps it
/// running in the background over Bluetooth); this extension only draws them.
@main
struct NPDongleWidgets: WidgetBundle {
    var body: some Widget {
        UpdateLiveActivity()
        StatusLiveActivity()
    }
}

// MARK: firmware update

struct UpdateLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DongleUpdateAttributes.self) { context in
            UpdateLockScreen(version: context.attributes.version, state: context.state, stale: context.isStale)
                .activityBackgroundTint(ActivityPalette.background.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let color = ActivityPalette.color(state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Dongle").font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: state.phase.symbol).foregroundStyle(color)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.phase.isFinal ? context.attributes.version : "\(state.percent)%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(state.phase.title) · firmware \(context.attributes.version)").font(.callout.weight(.semibold))
                        if !state.phase.isFinal { ProgressView(value: state.progress).tint(color) }
                        if !state.detail.isEmpty { Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            } compactLeading: {
                Image(systemName: state.phase.symbol).foregroundStyle(color)
            } compactTrailing: {
                if state.phase.isFinal {
                    Image(systemName: state.phase == .done ? "checkmark" : "xmark").foregroundStyle(color)
                } else {
                    Text("\(state.percent)%").monospacedDigit().foregroundStyle(color)
                }
            } minimal: {
                if state.phase.isFinal {
                    Image(systemName: state.phase.symbol).foregroundStyle(color)
                } else {
                    ProgressView(value: state.progress) { Image(systemName: "cpu").font(.caption2) }
                        .progressViewStyle(.circular)
                        .tint(color)
                }
            }
            .keylineTint(color)
        }
    }
}

struct UpdateLockScreen: View {
    let version: String
    let state: DongleUpdateAttributes.ContentState
    let stale: Bool

    var body: some View {
        let color = ActivityPalette.color(state.phase)
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: 5)
                Circle().trim(from: 0, to: state.phase.isFinal ? 1 : state.progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: state.phase.symbol).font(.title3).foregroundStyle(color)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dongle firmware \(version)").font(.headline)
                HStack {
                    Text(state.phase.title)
                    if !state.phase.isFinal { Text("· \(state.percent)%").monospacedDigit() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                if stale {
                    Text("Open NP Dongle to see how it's going.").font(.caption).foregroundStyle(.secondary)
                } else if !state.detail.isEmpty {
                    Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

// MARK: dongle status

struct StatusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DongleStatusAttributes.self) { context in
            StatusLockScreen(name: context.attributes.dongleName, state: context.state, stale: context.isStale)
                .activityBackgroundTint(ActivityPalette.background.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let tint = state.connected ? ActivityPalette.accent : ActivityPalette.danger
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(state.hostName, systemImage: state.hostSymbol)
                        .font(.caption.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BatteryLabel(battery: state.battery, charging: state.charging)
                        .font(.caption.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Label(state.profileName, systemImage: state.profileSymbol).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.connected ? "Band: \(state.bandState)" : "The dongle is out of reach")
                        .font(.caption)
                        .foregroundStyle(state.bandLive ? ActivityPalette.mint : ActivityPalette.warn)
                }
            } compactLeading: {
                Image(systemName: state.hostSymbol).foregroundStyle(tint)
            } compactTrailing: {
                Text(state.profileName).lineLimit(1).frame(maxWidth: 64).foregroundStyle(tint)
            } minimal: {
                Image(systemName: state.connected ? state.profileSymbol : "cable.connector.slash").foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }
}

struct StatusLockScreen: View {
    let name: String
    let state: DongleStatusAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.profileSymbol)
                .font(.title2)
                .foregroundStyle(ActivityPalette.accent)
                .frame(width: 48, height: 48)
                .background(ActivityPalette.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(state.profileName).font(.headline)
                Label(state.hostName, systemImage: state.hostSymbol).font(.subheadline).foregroundStyle(.secondary)
                Text(stale ? "Not updating: open NP Dongle" : state.connected ? "Band: \(state.bandState)" : "\(name) is out of reach")
                    .font(.caption)
                    .foregroundStyle(stale || !state.connected ? ActivityPalette.warn : state.bandLive ? ActivityPalette.mint : ActivityPalette.warn)
            }
            Spacer(minLength: 0)
            BatteryLabel(battery: state.battery, charging: state.charging).font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

struct BatteryLabel: View {
    let battery: Int?
    let charging: Bool

    var body: some View {
        if let battery {
            Label("\(battery)%", systemImage: charging ? "battery.100.bolt" : Self.symbol(battery))
                .monospacedDigit()
                .foregroundStyle(battery <= 15 && !charging ? ActivityPalette.danger : .white)
        } else {
            Label("—", systemImage: "battery.0").foregroundStyle(.secondary)
        }
    }

    static func symbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }
}
