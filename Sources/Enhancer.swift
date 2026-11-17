import Foundation
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import Observation

// MARK: - Albüm yardımcıları

enum Albums {
    /// Bu isimde albüm varsa onu, yoksa yenisini oluşturup kimliğini döndürür.
    static func ensure(_ title: String) -> String? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title == %@", title)
        if let c = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject {
            return c.localIdentifier
        }
        var id: String?
        try? PHPhotoLibrary.shared().performChangesAndWait {
            id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        return id
    }

    static func collection(_ id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }
}

// MARK: - Görüntü iyileştirme

struct EnhanceOptions {
    var upscale = true
    var denoise = true
    var sharpen = true
    var autoColor = true
}

enum Enhancer {
    static let maxLongSide: CGFloat = 8192
    static let context = CIContext(options: [.cacheIntermediates: false, .highQualityDownsample: true])

    /// Orijinal veriden iyileştirilmiş HEIC üretir. (Orijinale dokunmaz.)
    static func enhance(_ data: Data, _ o: EnhanceOptions) -> (Data, CGSize)? {
        guard var img = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let colorSpace = img.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!

        if o.autoColor {
            for f in img.autoAdjustmentFilters(options: [.redEye: false]) {
                f.setValue(img, forKey: kCIInputImageKey)
                if let out = f.outputImage { img = out }
            }
        }

        if o.denoise {
            let f = CIFilter.noiseReduction()
            f.inputImage = img
            f.noiseLevel = 0.02
            f.sharpness = 0.4
            if let out = f.outputImage { img = out }
        }

        var scale: CGFloat = 1
        if o.upscale {
            let longSide = max(img.extent.width, img.extent.height)
            scale = min(2.0, maxLongSide / max(longSide, 1))
            if scale > 1.05 {
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = img
                f.scale = Float(scale)
                f.aspectRatio = 1
                if let out = f.outputImage { img = out }
            } else {
                scale = 1
            }
        }

        if o.sharpen {
            let f = CIFilter.unsharpMask()
            f.inputImage = img
            f.radius = Float(1.2 * scale)
            f.intensity = 0.45
            if let out = f.outputImage { img = out }
        }

        let rect = img.extent.integral
        img = img.cropped(to: rect)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let heic = context.heifRepresentation(of: img, format: .RGBA8, colorSpace: colorSpace,
                                                    options: [quality: 0.95]) else { return nil }
        return (heic, rect.size)
    }
}

@Observable
final class EnhanceModel {
    var options = EnhanceOptions()
    var selected: [PHAsset] = []
    var running = false
    var done = 0
    var failed = 0
    var total = 0
    var lastSize: String = ""
    var finished = false

    func setSelection(identifiers: [String]) {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var map: [String: PHAsset] = [:]
        fetch.enumerateObjects { a, _, _ in map[a.localIdentifier] = a }
        selected = identifiers.compactMap { map[$0] }.filter { $0.mediaType == .image }
        finished = false
    }

    func run() {
        guard !running, !selected.isEmpty else { return }
        running = true; finished = false
        done = 0; failed = 0; total = selected.count; lastSize = ""
        let assets = selected
        let opts = options
        UIApplication.shared.isIdleTimerDisabled = true

        Thread.detachNewThread { [weak self] in
            let albumID = Albums.ensure("İyileştirilmiş (Hızlı Aktar)")
            for asset in assets {
                var ok = false
                var sizeText = ""
                autoreleasepool {
                    guard let data = EnhanceModel.originalData(asset),
                          let enhanced = Enhancer.enhance(data, opts) else { return }
                    let heic = enhanced.0
                    let size = enhanced.1
                    let base = (PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "IMG") as NSString
                    let name = base.deletingPathExtension + "_HD.HEIC"
                    do {
                        try PHPhotoLibrary.shared().performChangesAndWait {
                            let req = PHAssetCreationRequest.forAsset()
                            let ro = PHAssetResourceCreationOptions()
                            ro.originalFilename = name
                            req.addResource(with: .photo, data: heic, options: ro)
                            req.creationDate = asset.creationDate
                            req.location = asset.location
                            if let id = albumID, let album = Albums.collection(id),
                               let ph = req.placeholderForCreatedAsset {
                                PHAssetCollectionChangeRequest(for: album)?.addAssets([ph] as NSArray)
                            }
                        }
                        ok = true
                        sizeText = "\(asset.pixelWidth)×\(asset.pixelHeight) → \(Int(size.width))×\(Int(size.height))"
                    } catch {}
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ok { self.done += 1; self.lastSize = sizeText } else { self.failed += 1 }
                }
            }
            DispatchQueue.main.async {
                self?.running = false
                self?.finished = true
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private static func originalData(_ asset: PHAsset) -> Data? {
        let o = PHImageRequestOptions()
        o.isSynchronous = true
        o.isNetworkAccessAllowed = true
        o.version = .current
        o.deliveryMode = .highQualityFormat
        var result: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, _ in
            result = data
        }
        return result
    }
}
