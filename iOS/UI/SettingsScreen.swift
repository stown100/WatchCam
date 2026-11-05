import SwiftUI

struct SettingsScreen: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = coordinator.settings
        let capture = settings.values.capture

        NavigationStack {
            Form {
                Section {
                    Picker("Разрешение", selection: $settings.values.capture.resolution) {
                        ForEach(CaptureSettings.Resolution.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Частота кадров", selection: $settings.values.capture.frameRate) {
                        ForEach(CaptureSettings.frameRates, id: \.self) { Text("\($0) к/с").tag($0) }
                    }
                    Picker("Кодек", selection: $settings.values.capture.codec) {
                        ForEach(CaptureSettings.Codec.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(capture.hdr)
                    Toggle("HDR (10 бит, HLG)", isOn: $settings.values.capture.hdr)
                    Picker("Стабилизация", selection: $settings.values.capture.stabilization) {
                        ForEach(CaptureSettings.Stabilization.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Превью кадра на часах", isOn: $settings.values.capture.watchPreview)
                } header: {
                    Text("Видео")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !coordinator.camera.activeFormatSummary.isEmpty {
                            Text("Сейчас: \(coordinator.camera.activeFormatSummary)")
                        }
                        if let storage = storageEstimate(for: capture) {
                            Text(storage)
                        }
                        if capture.hdr {
                            if coordinator.camera.supportsHDR(capture) {
                                Text("HDR пишется только в HEVC.")
                            } else {
                                Text("Эта камера не снимает HDR в \(capture.resolution.title) \(capture.frameRate) к/с: запись пойдёт в SDR.")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("На штативе стабилизация не нужна: «Выключена» даёт самый широкий угол без обрезки кадра.")
                    }
                }

                Section {
                    Picker("Формат", selection: $settings.values.watchAudioFormat) {
                        ForEach(WatchAudioFormat.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Звук с часов")
                } footer: {
                    Text("AAC с максимальным качеством на слух не отличается от оригинала (узкое место — сам микрофон часов), а файл в 4–6 раз меньше и быстрее доходит до iPhone по Bluetooth. PCM — без потерь, для серьёзной обработки звука, но длинные записи передаются заметно дольше.")
                }

                Section {
                    Toggle("Автосохранение в Фото", isOn: $settings.values.autoSaveToPhotos)
                    Toggle("Звук iPhone второй дорожкой", isOn: $settings.values.includePhoneAudioTrack)
                    Toggle("Удалять исходники после сохранения", isOn: $settings.values.deleteSourcesAfterSave)
                } header: {
                    Text("После записи")
                } footer: {
                    Text("Автосохранение пропускает ролики с приблизительной синхронизацией: их стоит сначала проверить. Исходники (видео и звук часов отдельно) нужны для ручной подстройки и экспорта в «Файлы»; без них запись занимает вдвое меньше места.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    /// "Free 52 GB ≈ 2 h 10 min" using typical iPhone bit rates for the chosen format.
    private func storageEstimate(for capture: CaptureSettings) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free > 0 else { return nil }

        // Approximate Camera-app bit rates, Mbit/s.
        var megabits: Double = capture.resolution == .uhd4K ? 45 : 16
        megabits *= Double(capture.frameRate) / 30
        if capture.codec == .h264, !capture.hdr { megabits *= 1.6 }
        // The take is stored twice for a while: source + exported copy for Photos.
        let seconds = Double(free) * 8 / (megabits * 1_000_000) / 2
        let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        let duration = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "Свободно \(freeText) — примерно \(duration) записи."
    }
}
