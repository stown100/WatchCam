import Foundation
import Photos

/// Saves finished clips with add-only access: the app can put videos into Photos
/// but never sees the user's library.
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "Нет доступа к Фото. Разрешите добавление в Настройках → Конфиденциальность → Фото → WatchCam."
        }
    }

    /// Moves (not copies) the file into the library, so a multi-gigabyte clip doesn't need double space.
    static func saveVideo(at url: URL, creationDate: Date) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.accessDenied }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = creationDate
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: url, options: options)
        }
    }
}
