import SwiftUI

/// All takes with their status.
struct LibraryScreen: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var reviewTarget: ReviewTarget?

    var body: some View {
        NavigationStack {
            List {
                ForEach(coordinator.store.sessions) { session in
                    Button {
                        reviewTarget = ReviewTarget(id: session.id)
                    } label: {
                        SessionRow(session: session, diskUsage: coordinator.store.diskUsage(of: session.id))
                    }
                    .foregroundStyle(.primary)
                    .deleteDisabled(session.status == .recording || coordinator.processor.busy.contains(session.id))
                }
                .onDelete { offsets in
                    let ids = offsets.map { coordinator.store.sessions[$0].id }
                    ids.forEach(coordinator.store.delete)
                }
            }
            .overlay {
                if coordinator.store.sessions.isEmpty {
                    ContentUnavailableView("Записей пока нет", systemImage: "video",
                                           description: Text("Нажмите кнопку записи на iPhone или на часах."))
                }
            }
            .navigationTitle("Записи")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .fullScreenCover(item: $reviewTarget) { target in
                ReviewScreen(sessionID: target.id)
            }
        }
    }
}

private struct SessionRow: View {
    let session: RecordingSession
    let diskUsage: Int64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.usesWatch ? "applewatch" : "iphone")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                HStack(spacing: 6) {
                    if let duration = session.videoDuration {
                        Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    }
                    Text(ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                    if session.sync?.isApproximate == true {
                        Text("· примерно")
                            .foregroundStyle(.yellow)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: session.status)
        }
        .padding(.vertical, 2)
    }
}
