import AVFoundation
import SwiftUI

struct CameraScreen: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var reviewSession: ReviewTarget?
    /// Where the user last tapped, in screen coordinates (for the focus square).
    @State private var focusPoint: CGPoint?
    /// Restarts the focus square animation on every tap.
    @State private var focusTapCount = 0

    var body: some View {
        @Bindable var coordinator = coordinator
        let camera = coordinator.camera

        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(
                camera: camera,
                onTap: { point, devicePoint in
                    focusPoint = point
                    focusTapCount += 1
                    camera.focusAndExpose(at: devicePoint, lock: false)
                },
                onLongPress: { point, devicePoint in
                    focusPoint = point
                    focusTapCount += 1
                    camera.focusAndExpose(at: devicePoint, lock: true)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            )
            .ignoresSafeArea()

            if camera.hasUserFocusPoint, let focusPoint {
                FocusSquare(isLocked: camera.isFocusLocked)
                    .position(focusPoint)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .id(focusTapCount)
            }

            VStack(spacing: 12) {
                topBar
                if let message = camera.interruptionMessage {
                    Banner(text: message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                if let warning = coordinator.thermalWarning {
                    Banner(text: warning, systemImage: "thermometer.sun.fill", tint: .orange)
                }
                if camera.isFocusLocked {
                    Banner(text: "Фокус и экспозиция заблокированы", systemImage: "lock.fill", tint: .yellow)
                }
                Spacer()
                if camera.hasUserFocusPoint {
                    ExposureSlider(camera: camera)
                }
                ZoomBar(camera: camera)
                bottomBar
                LastTakeBanner { id in reviewSession = ReviewTarget(id: id) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if case .unauthorized = camera.status {
                PermissionOverlay()
            }
            if case .failed(let message) = camera.status {
                Label(message, systemImage: "video.slash")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .statusBarHidden()
        .alert(
            coordinator.prompt?.title ?? "",
            isPresented: Binding(get: { coordinator.prompt != nil }, set: { if !$0 { coordinator.prompt = nil } }),
            presenting: coordinator.prompt
        ) { prompt in
            if prompt.offersPhoneOnly {
                Button("Записать только с iPhone") { coordinator.startFromPhone(phoneOnly: true) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryScreen()
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen()
        }
        .fullScreenCover(item: $reviewSession) { target in
            ReviewScreen(sessionID: target.id)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            WatchBadge()
            Spacer()
            RecordingTimer(start: coordinator.recordingStartedAt)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Text(coordinator.settings.values.capture.summary)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .disabled(coordinator.phase != .idle)
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack {
            CircleIconButton(systemImage: "photo.on.rectangle", rotation: iconRotation) {
                showLibrary = true
            }
            .disabled(coordinator.phase != .idle)

            Spacer()
            RecordButton(phase: coordinator.phase) {
                coordinator.recordButtonTapped()
            }
            .disabled(coordinator.camera.status != .ready)
            Spacer()

            CircleIconButton(systemImage: "arrow.triangle.2.circlepath.camera", rotation: iconRotation) {
                coordinator.camera.switchCamera()
            }
            .disabled(coordinator.phase != .idle)
        }
        .padding(.horizontal, 12)
    }

    /// Icons counter-rotate when the phone is held sideways (the UI itself stays portrait).
    private var iconRotation: Angle {
        .degrees(90 - coordinator.camera.deviceRotationAngle)
    }
}

struct ReviewTarget: Identifiable {
    let id: UUID
}

// MARK: - Pieces

private struct WatchBadge: View {
    @Environment(RecordingCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "applewatch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            if let level = coordinator.watchLevelDB {
                AudioLevelBar(levelDB: level)
                    .frame(width: 90, height: 5)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var text: String {
        if coordinator.phase == .recording, !coordinator.recordingUsesWatch { return "Только iPhone" }
        if let note = coordinator.watchRecordingNote { return note.text }
        switch coordinator.watchState {
        case .notPaired: return "Нет часов"
        case .appNotInstalled: return "Нет приложения"
        // Usually it's just the app on the watch being off screen: live messages only work while it's on.
        case .unreachable: return "Откройте WatchCam"
        case .appNotActive: return "Откройте WatchCam"
        case .ready: return "Готовы"
        case .recording: return "Пишут звук"
        }
    }

    private var color: Color {
        if let note = coordinator.watchRecordingNote {
            return switch note.kind {
            case .fine: .red
            case .unknown: .yellow
            case .problem: .orange
            }
        }
        return switch coordinator.watchState {
        case .ready: .green
        case .recording: .red
        case .appNotActive: .yellow
        case .notPaired, .appNotInstalled, .unreachable: .orange
        }
    }
}

struct AudioLevelBar: View {
    let levelDB: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule()
                    .fill(levelDB > -3 ? Color.red : levelDB > -12 ? .yellow : .green)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(1, (levelDB + 60) / 60))))
            }
        }
        .animation(.linear(duration: 0.2), value: levelDB)
    }
}

private struct RecordingTimer: View {
    let start: Date?

    var body: some View {
        if let start {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.red, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct ZoomBar: View {
    let camera: CameraController

    var body: some View {
        HStack(spacing: 10) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let isActive = activePreset == preset
                Button {
                    camera.setZoom(preset, animated: true)
                } label: {
                    Text(isActive ? label(camera.displayZoom, active: true) : label(preset, active: false))
                        .font(.system(size: isActive ? 13 : 11, weight: .bold, design: .rounded))
                        .foregroundStyle(isActive ? .yellow : .white)
                        .frame(width: isActive ? 40 : 32, height: isActive ? 40 : 32)
                        .background(.black.opacity(0.55), in: Circle())
                }
            }
        }
        .padding(6)
        .background(.black.opacity(0.25), in: Capsule())
        .animation(.easeOut(duration: 0.15), value: activePreset)
    }

    /// The preset at or below the current zoom: that "lens" is highlighted, like in the Camera app.
    private var activePreset: CGFloat? {
        camera.zoomPresets.last { $0 <= camera.displayZoom + 0.05 } ?? camera.zoomPresets.first
    }

    private func label(_ value: CGFloat, active: Bool) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return active ? text + "×" : (value < 1 ? ".5" : text)
    }
}

private struct FocusSquare: View {
    let isLocked: Bool
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: 76, height: 76)
            .scaleEffect(settled ? 1 : 1.35)
            .opacity(settled && !isLocked ? 0.45 : 1)
            .onAppear {
                withAnimation(.spring(duration: 0.3)) { settled = true }
            }
    }
}

/// Exposure compensation (EV), shown after the user picked a focus point.
private struct ExposureSlider: View {
    let camera: CameraController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.yellow)
            Slider(
                value: Binding(get: { Double(camera.exposureBias) }, set: { camera.setExposureBias(Float($0)) }),
                in: Double(camera.exposureBiasRange.lowerBound)...Double(camera.exposureBiasRange.upperBound)
            )
            .tint(.yellow)
            Text(String(format: "%+.1f", camera.exposureBias))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 36)
            Button {
                camera.resetFocus()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .accessibilityLabel("Сбросить фокус и экспозицию")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.5), in: Capsule())
    }
}

private struct RecordButton: View {
    let phase: RecordingCoordinator.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 5)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 34)
                    .fill(.red)
                    .padding(isRecording ? 22 : 8)
                if phase == .startingWatch || phase == .stopping {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 78, height: 78)
            .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
        .accessibilityLabel(isRecording ? "Остановить запись" : "Начать запись")
    }

    private var isRecording: Bool { phase == .recording || phase == .stopping }
}

struct CircleIconButton: View {
    let systemImage: String
    var rotation: Angle = .zero
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(.black.opacity(0.5), in: Circle())
                .rotationEffect(rotation)
                .animation(.easeInOut, value: rotation)
        }
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    var tint: Color = .white

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
    }
}

/// Status of the last take under the record button. Tap to open it.
private struct LastTakeBanner: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    let open: (UUID) -> Void

    var body: some View {
        if coordinator.phase == .idle, let id = coordinator.lastSessionID, let session = coordinator.store.session(id) {
            Button { open(id) } label: {
                HStack(spacing: 8) {
                    icon(for: session)
                    Text(text(for: session))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func icon(for session: RecordingSession) -> some View {
        switch session.status {
        case .waitingForWatch, .processing, .recording:
            ProgressView().controlSize(.small).tint(.white)
        case .ready:
            Image(systemName: session.sync?.isApproximate == true ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(session.sync?.isApproximate == true ? .yellow : .green)
        case .saved:
            Image(systemName: "photo.badge.checkmark").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func text(for session: RecordingSession) -> String {
        if session.status == .waitingForWatch {
            if let progress = coordinator.watchTransferProgress { return "Звук с часов: \(Int(progress * 100))%" }
            // watchOS may hold the file while the watch is locked or the app is off screen.
            return "Ждём звук: откройте WatchCam на часах"
        }
        if coordinator.processor.busy.contains(session.id), session.status == .ready {
            return "Сохранение в Фото…"
        }
        if session.status == .ready, session.sync?.isApproximate == true {
            return "Синхронизация приблизительная — проверьте"
        }
        return session.status.title
    }
}

private struct PermissionOverlay: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
            Text("Нет доступа к камере")
                .font(.headline)
            Text("Разрешите доступ в Настройках, чтобы снимать видео.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .foregroundStyle(.white)
    }
}
