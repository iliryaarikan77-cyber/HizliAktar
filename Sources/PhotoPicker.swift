import SwiftUI
import PhotosUI
import Photos

/// Fotoğraflar kütüphanesinden sınırsız çoklu seçim (parmağı sürükleyerek toplu seçim destekli).
struct PhotoPicker: UIViewControllerRepresentable {
    var filter: PHPickerFilter? = nil
    var limit: Int = 0                 // 0 = sınırsız
    var onPick: ([String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = limit
        config.filter = filter
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([String]) -> Void
        init(onPick: @escaping ([String]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let ids = results.compactMap { $0.assetIdentifier }
            onPick(ids)
        }
    }
}

// MARK: - Kütüphane izni

@Observable
final class LibraryAccess {
    var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var isFull: Bool { status == .authorized }

    func request() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
            DispatchQueue.main.async { self.status = s }
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
