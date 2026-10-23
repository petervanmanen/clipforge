#if os(iOS)
import Photos

extension EditorModel {
    /// Adds the last export to the photo library (asks for add-only access the first time).
    func saveExportToPhotos() {
        guard let url = lastExportURL else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                errorMessage = "FitMovie isn't allowed to add videos to Photos. You can change this in Settings › Privacy › Photos."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                }
                savedToPhotos = true
            } catch {
                errorMessage = "Couldn't save to Photos: \(error.localizedDescription)"
            }
        }
    }
}
#endif
