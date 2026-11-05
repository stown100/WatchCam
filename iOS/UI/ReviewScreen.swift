import AVKit
import SwiftUI

/// After-recording screen: preview of the merged clip, sync details and actions.
struct ReviewScreen: View {
    let sessionID: UUID

    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var playerError: String?
    @State private var sharedFiles: SharedFiles?
    @State private var exportedSources: SharedFiles?
    @State private var offsetMs: Double = 0
    @State private var working: String?
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    private var session: RecordingSession? { coordinator.store.session(sessionID) }
    private var processor: SessionProcessor { coordinator.processor }
    private var isBusy: Bool { processor.busy.contains(sessionID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let session {
                    VStack(alignment: .leading, spacing: 16) {
                        playerView(for: session)
                        StatusCard(session: session, transferProgress: coordinator.watchTransferProgress, isBusy: isBusy)
                        if session.usesWatch, session.sync != nil, !session.sourcesDeleted {
                            OffsetAdjuster(valueMs: $offsetMs) { committed in
                                processor.setManualOffset(committed / 1000, for: sessionID)
                            }
                            .disabled(isBusy)
                        }
                        actions(for: session)
                    }
                    .padding(16)
                } else {
                    ContentUnavailableView("Запись удалена", systemImage: "trash")
                }
            }
            .navigationTitle(session.map { $0.createdAt.formatted(date: .abbreviated, time: .shortened) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .overlay {
                if let working {
                    ProgressView(working)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Не получилось", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Удалить запись?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    player.replaceCurrentItem(with: nil)
                    coordinator.store.delete(sessionID)
                    dismiss()
                }
            } message: {
                Text("Видео и звук с часов будут удалены из приложения. Уже сохранённое в Фото останется.")
            }
            .sheet(item: $sharedFiles, onDismiss: cleanUpSharedFiles) { files in
                ActivityView(items: files.urls)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $exportedSources, onDismiss: {
                try? FileManager.default.removeItem(at: SessionProcessor.sourcesExportFolder(for: sessionID))
            }) { files in
                DocumentExporter(urls: files.urls) { exportedSources = nil }
                    .ignoresSafeArea()
            }
        }
        .task(id: compositionKey) {
            await reloadPlayer()
        }
        .onAppear { offsetMs = (session?.manualOffset ?? 0) * 1000 }
        .onDisappear { player.pause() }
    }

    // MARK: - Player

    @ViewBuilder
    private func playerView(for session: RecordingSession) -> some View {
        if session.sourcesDeleted {
            placeholder("Исходники удалены после сохранения в Фото", systemImage: "externaldrive.badge.checkmark")
        } else if !session.videoFinished {
            placeholder("Видео ещё записывается", systemImage: "record.circle")
        } else if let playerError {
            placeholder(playerError, systemImage: "exclamationmark.triangle")
        } else {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                Label(text, systemImage: systemImage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
            }
    }

    /// Changes whenever the merged result would change, so the preview is rebuilt.
    private var compositionKey: String {
        guard let session else { return "" }
        return [
            session.status.rawValue,
            "\(session.usesWatch)",
            "\(session.sync?.offset ?? .nan)",
            "\(session.manualOffset)",
            session.correctedAudioFileName ?? "",
            "\(coordinator.settings.values.includePhoneAudioTrack)",
        ].joined(separator: "|")
    }

    private func reloadPlayer() async {
        guard let session, session.videoFinished, !session.sourcesDeleted, session.status != .processing else { return }
        do {
            let composition = try await processor.composition(for: session)
            let resumeAt = player.currentTime()
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            playerError = nil

            // Keep the position when the preview is rebuilt (e.g. after a manual offset change).
            // A player without an item reports an invalid time, and seeking to it throws an exception.
            if resumeAt.isNumeric {
                await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } catch {
            playerError = error.localizedDescription
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(for session: RecordingSession) -> some View {
        let canExport = session.videoFinished && !session.sourcesDeleted && !isBusy
            && (session.status == .ready || session.status == .saved)

        VStack(spacing: 10) {
            if session.status == .waitingForWatch {
                Button {
                    processor.useIPhoneAudioOnly(sessionID)
                } label: {
                    Label("Не ждать часы: звук iPhone", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                run("Сохранение в Фото…") { try await processor.saveToPhotos(sessionID) }
            } label: {
                Label(session.status == .saved ? "Сохранить в Фото ещё раз" : "Сохранить в Фото", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExport)

            Button {
                run("Подготовка ролика…") {
                    let url = try await processor.exportClip(sessionID)
                    sharedFiles = SharedFiles(urls: [url])
                }
            } label: {
                Label("Поделиться", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canExport)

            Button {
                run("Подготовка исходников…") {
                    exportedSources = SharedFiles(urls: try await processor.exportSources(sessionID))
                }
            } label: {
                Label("Исходники в «Файлы»", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canExport)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Удалить", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(session.status == .recording || isBusy)
        }
        .controlSize(.large)
    }

    private func run(_ title: String, _ work: @escaping () async throws -> Void) {
        player.pause()
        working = title
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            working = nil
        }
    }

    /// Exported copies for sharing are temporary.
    private func cleanUpSharedFiles() {
        sharedFiles?.urls.forEach { try? FileManager.default.removeItem(at: $0) }
        sharedFiles = nil
    }
}

struct SharedFiles: Identifiable {
    let id = UUID()
    var urls: [URL]
}

// MARK: - Status

private struct StatusCard: View {
    let session: RecordingSession
    let transferProgress: Double?
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusBadge(status: session.status)
                if isBusy, session.status != .processing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Идёт экспорт")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let duration = session.videoDuration {
                    Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text(session.captureSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let info = session.watchInfo {
                Text("Звук часов: \(info.format == .aac ? "AAC" : "PCM 16 бит"), \(Int(info.sampleRate)) Гц (микрофон: \(Int(info.hardwareSampleRate)) Гц)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if info.silenceInserted > 0.05 {
                    Label(String(format: "Запись на часах прерывалась: вставлено %.1f с тишины", info.silenceInserted),
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            syncDescription
                .font(.footnote)
            if let error = session.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var syncDescription: some View {
        if !session.usesWatch {
            Text("Звук с микрофона iPhone.")
        } else if session.status == .waitingForWatch {
            if let transferProgress {
                Text("Часы передают звук: \(Int(transferProgress * 100))%")
            } else {
                Text("Ждём файл с часов. Он придёт сам, когда часы будут рядом с iPhone, даже если закрыть приложение.")
            }
        } else if let sync = session.sync {
            switch sync.method {
            case .crossCorrelation:
                let offset = String(format: "%.3f", sync.offset)
                let drift = abs(sync.driftPPM) >= 1 ? String(format: ", дрейф часов %.0f ppm", sync.driftPPM) : ""
                Label("Синхронизировано по звуку: смещение \(offset) с, уверенность \(Int(sync.confidence * 100))%\(drift)",
                      systemImage: "waveform.badge.checkmark")
                    .foregroundStyle(.green)
            case .coarse:
                Label("Синхронизация приблизительная: iPhone почти ничего не слышал, использовано время устройств. Проверьте синхрон губ.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }
        }
    }
}

struct StatusBadge: View {
    let status: RecordingSession.Status

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .recording: .red
        case .waitingForWatch, .processing: .orange
        case .ready: .blue
        case .saved: .green
        case .failed: .red
        }
    }
}

// MARK: - Manual offset

/// Fine-tunes the audio position when the automatic sync got it wrong.
private struct OffsetAdjuster: View {
    @Binding var valueMs: Double
    let commit: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Сдвиг звука")
                    .font(.headline)
                Spacer()
                Text(description)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $valueMs, in: -500...500, step: 1) { editing in
                if !editing { commit(valueMs) }
            }
            HStack {
                nudge(-10)
                nudge(-1)
                Spacer()
                Button("Сбросить") {
                    valueMs = 0
                    commit(0)
                }
                .disabled(valueMs == 0)
                Spacer()
                nudge(1)
                nudge(10)
            }
            .buttonStyle(.bordered)
            Text("Если губы и звук расходятся, сдвиньте звук: «+» — звук позже, «−» — раньше.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var description: String {
        guard valueMs != 0 else { return "0 мс" }
        return String(format: "%+.0f мс", valueMs) + (valueMs > 0 ? " (позже)" : " (раньше)")
    }

    private func nudge(_ delta: Double) -> some View {
        Button(delta > 0 ? "+\(Int(delta))" : "\(Int(delta))") {
            valueMs = min(500, max(-500, valueMs + delta))
            commit(valueMs)
        }
        .monospacedDigit()
    }
}

/// "Save to Files" picker for several files at once.
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}

/// UIActivityViewController (share sheet) for SwiftUI.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
