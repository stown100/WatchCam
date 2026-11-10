import SwiftUI

/// Two pages, swiped horizontally: controls and the camera frame.
/// The Digital Crown zooms the iPhone camera on both.
struct RootView: View {
    @Environment(WatchModel.self) private var model
    @State private var page = 0
    /// The crown's own value. Only its changes matter: `MagneticCrown` keeps the position on the
    /// zoom dial, because steps have to swallow rotation. The range is just "never reached":
    /// crown speed depends on the sensitivity, not on the range.
    @State private var crownValue = 0.0
    private static let crownTravel = 100_000.0

    var body: some View {
        TabView(selection: $page) {
            RecorderView().tag(0)
            PreviewPage().tag(1)
        }
        .tabViewStyle(.page)
        .focusable()
        // Haptics off: the clicks are vibrations right next to the microphone, and they get recorded.
        .digitalCrownRotation($crownValue, from: -Self.crownTravel, through: Self.crownTravel,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: false)
        .onChange(of: crownValue) { _, raw in
            model.crownMoved(to: raw)
        }
        // The zoom changed on the phone (pinch, lens buttons), or another camera brought another dial.
        .onChange(of: model.phoneZoom, initial: true) { model.syncCrownToPhone() }
        .onChange(of: model.zoomDial) { model.syncCrownToPhone(dialChanged: true) }
        .onChange(of: page, initial: true) { _, page in
            model.isPreviewVisible = page == 1
        }
    }
}

struct RecorderView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                PhoneStatusRow(state: model.phoneState)
                if model.phoneState == .ready || model.phoneState == .recording {
                    ZoomBadge(zoom: model.phoneZoom)
                }
            }

            ElapsedTimeText(start: model.recordingStartedAt)

            if !isLuminanceReduced {
                LevelMeter(levelDB: model.levelDB, isActive: model.phase != .idle)
                    .frame(height: 6)
                    .padding(.horizontal, 8)
            }

            RecordButton(phase: model.phase, size: 76) {
                model.toggleRecording()
            }

            footer
                .frame(minHeight: 28)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var footer: some View {
        if let message = model.message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .onTapGesture { model.dismissMessage() }
        } else if model.pendingTransfers > 0 {
            VStack(spacing: 2) {
                Text("Отправка на iPhone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ProgressView(value: model.transferProgress ?? 0)
                    .tint(.blue)
            }
        } else {
            Color.clear
        }
    }
}

/// The iPhone's frame, updated as fast as the connection allows, to check framing from a distance.
private struct PreviewPage: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ZStack {
            if !isLuminanceReduced, let image = model.previewImage, model.isPreviewFresh {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "video")
                        .font(.title2)
                    Text(placeholderText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }

            VStack {
                HStack {
                    ElapsedTimeText(start: model.recordingStartedAt, size: 16)
                    Spacer()
                    ZoomBadge(zoom: model.phoneZoom)
                }
                Spacer()
                HStack {
                    Spacer()
                    RecordButton(phase: model.phase, size: 44) {
                        model.toggleRecording()
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var placeholderText: String {
        switch model.phoneState {
        case .ready, .recording: "Кадр загружается…"
        case .appNotActive: "Откройте WatchCam на iPhone"
        default: "iPhone недоступен"
        }
    }
}

private struct PhoneStatusRow: View {
    let state: WatchModel.PhoneState

    var body: some View {
        Label(text, systemImage: "iphone")
            .font(.footnote)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var text: String {
        switch state {
        case .unreachable: "iPhone недоступен"
        case .connecting: "Связь с iPhone…"
        case .appNotActive: "Откройте WatchCam на iPhone"
        case .cameraNotReady: "Камера готовится…"
        case .ready: "iPhone готов"
        case .recording: "iPhone снимает"
        }
    }

    private var color: Color {
        switch state {
        case .ready: .green
        case .recording: .red
        case .unreachable, .appNotActive: .orange
        case .connecting, .cameraNotReady: .secondary
        }
    }
}

private struct ZoomBadge: View {
    let zoom: Double

    var body: some View {
        Text(String(format: zoom < 10 ? "%.1f×" : "%.0f×", zoom))
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.yellow)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
    }
}

private struct ElapsedTimeText: View {
    let start: Date?
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let start {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
            } else {
                Text("0:00")
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(start == nil ? .secondary : .primary)
    }
}

struct LevelMeter: View {
    let levelDB: Float
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
                    .animation(.linear(duration: 0.1), value: fraction)
            }
        }
    }

    /// Maps -60...0 dBFS onto the bar.
    private var fraction: CGFloat {
        guard isActive else { return 0 }
        return CGFloat(max(0, min(1, (levelDB + 60) / 60)))
    }

    private var color: Color {
        if levelDB > -3 { return .red }
        if levelDB > -12 { return .yellow }
        return .green
    }
}

private struct RecordButton: View {
    let phase: WatchModel.Phase
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: size > 60 ? 4 : 3)
                RoundedRectangle(cornerRadius: isRecording ? size * 0.1 : size / 2)
                    .fill(.red)
                    .padding(isRecording ? size * 0.32 : size * 0.12)
                if phase == .starting {
                    ProgressView()
                }
            }
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Остановить запись" : "Начать запись")
    }

    private var isRecording: Bool { phase != .idle }
}
