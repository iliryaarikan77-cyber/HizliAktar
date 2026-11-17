import Foundation
import Network
import Photos
import UIKit
import Observation

// MARK: - Yakındaki iPhone'ları bulma

struct PeerInfo: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

final class PeerBrowser {
    private var browser: NWBrowser?
    var onChange: (([PeerInfo]) -> Void)?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: HA.serviceType, domain: nil), using: HA.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var peers: [PeerInfo] = []
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint {
                    if !peers.contains(where: { $0.name == name }) {
                        peers.append(PeerInfo(name: name, endpoint: r.endpoint))
                    }
                }
            }
            peers.sort { $0.name < $1.name }
            DispatchQueue.main.async { self?.onChange?(peers) }
        }
        b.stateUpdateHandler = { state in
            if case .failed = state { b.cancel() }
        }
        b.start(queue: DispatchQueue(label: "ha.browser"))
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

// MARK: - Gönderim planı

struct PlanItem {
    let index: Int
    let asset: PHAsset
    let resources: [(PHAssetResource, ResourceKind)]
    let originalName: String
    let key: String
    let estBytes: Int64
}

enum Planner {
    static func estimatedSize(_ r: PHAssetResource) -> Int64 {
        let sel = NSSelectorFromString("fileSize")
        if r.responds(to: sel), let n = r.value(forKey: "fileSize") as? NSNumber {
            return n.int64Value
        }
        return 3_000_000
    }

    static func makePlan(_ assets: [PHAsset], includeEdits: Bool) -> [PlanItem] {
        var items: [PlanItem] = []
        items.reserveCapacity(assets.count)
        for (i, asset) in assets.enumerated() {
            let all = PHAssetResource.assetResources(for: asset)
            func find(_ t: PHAssetResourceType) -> PHAssetResource? { all.first { $0.type == t } }

            var list: [(PHAssetResource, ResourceKind)] = []
            switch asset.mediaType {
            case .image:
                let editedPhoto = includeEdits ? find(.fullSizePhoto) : nil
                if let p = editedPhoto ?? find(.photo) { list.append((p, .photo)) }
                let editedPaired = includeEdits ? find(.fullSizePairedVideo) : nil
                if let pv = editedPaired ?? find(.pairedVideo) { list.append((pv, .pairedVideo)) }
                // RAW+JPEG çiftleri: düzenlenmemişse ikinci dosyayı da gönder
                if editedPhoto == nil, let alt = find(.alternatePhoto) { list.append((alt, .alternatePhoto)) }
            case .video:
                let edited = includeEdits ? find(.fullSizeVideo) : nil
                if let v = edited ?? find(.video) { list.append((v, .video)) }
            case .audio:
                if let a = find(.audio) { list.append((a, .audio)) }
            default:
                break
            }
            if list.isEmpty, let f = all.first {
                list.append((f, asset.mediaType == .video ? .video : .photo))
            }
            guard !list.isEmpty else { continue }

            let original = (find(.photo) ?? find(.video) ?? list[0].0).originalFilename
            let key = AssetKey.make(filename: original, date: asset.creationDate,
                                    width: asset.pixelWidth, height: asset.pixelHeight)
            let est = list.reduce(Int64(0)) { $0 + estimatedSize($1.0) }
            items.append(PlanItem(index: i, asset: asset, resources: list,
                                  originalName: original, key: key, estBytes: est))
        }
        return items
    }
}

// MARK: - Gönderim motoru

final class SendEngine {
    private let items: [PlanItem]
    private let endpoint: NWEndpoint
    private let parallel: Int
    private let deviceName: String
    private let albumTitle: String?
    private let sessionID = UUID().uuidString

    private let lock = NSLock()
    private var queue: [PlanItem] = []
    private var finished = Set<Int>()
    private var _cancelled = false

    // İlerleme sayaçları (arayüz bunları okur)
    private(set) var totalBytes: Int64 = 0
    private(set) var sentBytes: Int64 = 0
    private(set) var doneAssets = 0
    private(set) var skippedAssets = 0
    private(set) var activeStreams = 0
    private(set) var status = "Hazırlanıyor…"

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    init(items: [PlanItem], endpoint: NWEndpoint, parallel: Int, deviceName: String, albumTitle: String?) {
        self.items = items
        self.endpoint = endpoint
        self.parallel = max(1, min(8, parallel))
        self.deviceName = deviceName
        self.albumTitle = albumTitle
        self.totalBytes = items.reduce(Int64(0)) { $0 + $1.estBytes }
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    func snapshot() -> (total: Int64, sent: Int64, done: Int, skipped: Int, streams: Int, status: String) {
        lock.lock(); defer { lock.unlock() }
        return (totalBytes, sentBytes, doneAssets, skippedAssets, activeStreams, status)
    }

    private func setStatus(_ s: String) { lock.lock(); status = s; lock.unlock() }
    private func addSent(_ n: Int64) { lock.lock(); sentBytes += n; lock.unlock() }
    private func adjustTotal(_ delta: Int64) { lock.lock(); totalBytes += delta; lock.unlock() }
    private func streamDelta(_ d: Int) { lock.lock(); activeStreams += d; lock.unlock() }

    private func nextItem() -> PlanItem? {
        lock.lock(); defer { lock.unlock() }
        if _cancelled || queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    private func requeue(_ item: PlanItem) {
        lock.lock(); queue.insert(item, at: 0); lock.unlock()
    }

    private func markDone(_ item: PlanItem) {
        lock.lock(); finished.insert(item.index); doneAssets += 1; lock.unlock()
    }

    private func remainingCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    private func makeConnection(_ label: String) -> BlockingConnection {
        BlockingConnection(NWConnection(to: endpoint, using: HA.parameters()), label: label)
    }

    /// Engelleyen çağrı — arka plan iş parçacığında çalıştırın.
    func run() throws {
        // 1) Kontrol bağlantısı + manifest
        setStatus("Bağlanıyor…")
        let c0 = makeConnection("0")
        try c0.start()
        try c0.send(encodeJSONFrame(.hello, HelloMsg(sessionID: sessionID, deviceName: deviceName, connIndex: 0)))
        try c0.send(encodeJSONFrame(.manifest, ManifestMsg(keys: items.map { $0.key },
                                                          totalBytes: totalBytes,
                                                          albumTitle: albumTitle)))
        setStatus("Karşı telefon kütüphanesini kontrol ediyor…")
        let (type, body) = try c0.readFrame(timeout: 600)
        guard type == .skipList else { throw ProtoError.unexpected("Beklenmeyen yanıt") }
        let skip = Set((try? JSONDecoder().decode(SkipMsg.self, from: body))?.skip ?? [])

        lock.lock()
        queue = items.filter { !skip.contains($0.index) }
        skippedAssets = items.count - queue.count
        let skippedBytes = items.filter { skip.contains($0.index) }.reduce(Int64(0)) { $0 + $1.estBytes }
        totalBytes -= skippedBytes
        lock.unlock()

        if remainingCount() == 0 {
            try? c0.send(encodeFrame(.done))
            _ = try? c0.readFrame(timeout: 10)
            c0.cancel()
            setStatus("Hepsi zaten karşı telefonda")
            return
        }

        // 2) Paralel akışlar
        var round = 0
        var first: BlockingConnection? = c0
        while remainingCount() > 0 && !cancelled && round < 4 {
            round += 1
            setStatus(round == 1 ? "Gönderiliyor…" : "Bağlantı yenileniyor…")
            var conns: [BlockingConnection] = []
            if let f = first { conns.append(f); first = nil }
            let need = parallel - conns.count
            if need > 0 {
                let opened = openConnections(count: need, startIndex: round * 10)
                conns.append(contentsOf: opened)
            }
            if conns.isEmpty {
                Thread.sleep(forTimeInterval: 1.5)
                continue
            }
            let group = DispatchGroup()
            for c in conns {
                group.enter()
                Thread.detachNewThread { [weak self] in
                    self?.worker(c)
                    group.leave()
                }
            }
            group.wait()
        }

        if cancelled { throw ProtoError.unexpected("İptal edildi") }
        if remainingCount() > 0 { throw ProtoError.unexpected("Bağlantı koptu. Tekrar gönderirsen kaldığı yerden devam eder.") }
        setStatus("Tamamlandı")
    }

    private func openConnections(count: Int, startIndex: Int) -> [BlockingConnection] {
        var result: [BlockingConnection] = []
        let lockR = NSLock()
        let group = DispatchGroup()
        for i in 0..<count {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { group.leave() }
                let c = makeConnection("\(startIndex + i + 1)")
                do {
                    try c.start()
                    try c.send(encodeJSONFrame(.hello, HelloMsg(sessionID: sessionID, deviceName: deviceName,
                                                                connIndex: startIndex + i + 1)))
                    lockR.lock(); result.append(c); lockR.unlock()
                } catch {
                    c.cancel()
                }
            }
        }
        group.wait()
        return result
    }

    private func worker(_ c: BlockingConnection) {
        streamDelta(1)
        defer { streamDelta(-1) }
        while let item = nextItem() {
            do {
                try sendAsset(item, on: c)
                markDone(item)
            } catch {
                requeue(item)
                c.cancel()
                return
            }
        }
        // Bitti: karşı taraf kapatana kadar bekle (veri tamamen ulaşsın)
        do {
            try c.send(encodeFrame(.done))
            try c.flush()
            _ = try? c.readFrame(timeout: 60)
        } catch {}
        c.cancel()
    }

    private func export(_ res: PHAssetResource, to url: URL) throws {
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true   // iCloud'daki orijinali de indirir
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        PHAssetResourceManager.default().writeData(for: res, toFile: url, options: opts) { e in
            err = e
            sem.signal()
        }
        sem.wait()
        if let err { throw err }
    }

    private func importName(_ res: PHAssetResource, item: PlanItem) -> String {
        let name = res.originalFilename
        if name.lowercased().hasPrefix("fullsizerender") || name.isEmpty {
            let base = (item.originalName as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return ext.isEmpty ? item.originalName : "\(base).\(ext)"
        }
        return name
    }

    private func sendAsset(_ item: PlanItem, on c: BlockingConnection) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Orijinal dosyaları (dönüştürmeden, birebir) çıkar
        var infos: [ResourceInfo] = []
        var files: [URL] = []
        var actual: Int64 = 0
        for (n, pair) in item.resources.enumerated() {
            let url = dir.appendingPathComponent("r\(n)")
            try export(pair.0, to: url)
            let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            actual += size
            infos.append(ResourceInfo(kind: pair.1, filename: importName(pair.0, item: item), size: size))
            files.append(url)
        }
        adjustTotal(actual - item.estBytes)

        let a = item.asset
        let msg = AssetBeginMsg(index: item.index,
                                key: item.key,
                                creationDate: a.creationDate?.timeIntervalSince1970,
                                latitude: a.location?.coordinate.latitude,
                                longitude: a.location?.coordinate.longitude,
                                isFavorite: a.isFavorite,
                                resources: infos)
        try c.send(encodeJSONFrame(.assetBegin, msg))

        for (n, url) in files.enumerated() {
            try c.send(encodeFrame(.resourceBegin, Data([UInt8(n)])))
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            while true {
                if cancelled { throw ProtoError.unexpected("İptal") }
                guard let chunk = try fh.read(upToCount: HA.chunkSize), !chunk.isEmpty else { break }
                try c.send(encodeFrame(.data, chunk))
                addSent(Int64(chunk.count))
            }
            try c.send(encodeFrame(.resourceEnd))
        }
        try c.send(encodeFrame(.assetEnd))
    }
}

// MARK: - Gönder ekranının modeli

@Observable
final class SendModel {
    enum Phase: Equatable { case idle, preparing, sending, done, failed(String) }

    var selected: [PHAsset] = []
    var peers: [PeerInfo] = []
    var target: PeerInfo?
    var phase: Phase = .idle

    var totalBytes: Int64 = 0
    var sentBytes: Int64 = 0
    var doneAssets = 0
    var skippedAssets = 0
    var totalAssets = 0
    var streams = 0
    var speed: Double = 0
    var peakSpeed: Double = 0
    var status = ""
    var elapsed: TimeInterval = 0

    var parallel: Int = UserDefaults.standard.object(forKey: "parallel") as? Int ?? HA.defaultParallel
    var includeEdits: Bool = UserDefaults.standard.object(forKey: "includeEdits") as? Bool ?? true
    var putInAlbum: Bool = UserDefaults.standard.object(forKey: "putInAlbum") as? Bool ?? true

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(parallel, forKey: "parallel")
        d.set(includeEdits, forKey: "includeEdits")
        d.set(putInAlbum, forKey: "putInAlbum")
    }

    @ObservationIgnored private let browser = PeerBrowser()
    @ObservationIgnored private var engine: SendEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let meter = SpeedMeter()
    @ObservationIgnored private var startDate = Date()
    @ObservationIgnored private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var selectedSummary: String {
        let photos = selected.filter { $0.mediaType == .image }.count
        let videos = selected.filter { $0.mediaType == .video }.count
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) fotoğraf") }
        if videos > 0 { parts.append("\(videos) video") }
        return parts.isEmpty ? "Seçim yok" : parts.joined(separator: " · ")
    }

    var isBusy: Bool { phase == .preparing || phase == .sending }

    func startBrowsing() {
        browser.onChange = { [weak self] peers in
            guard let self else { return }
            self.peers = peers
            if let t = self.target, !peers.contains(where: { $0.name == t.name }), !self.isBusy {
                self.target = nil
            }
            if self.target == nil, peers.count == 1 { self.target = peers.first }
        }
        browser.start()
    }

    func stopBrowsing() { browser.stop() }

    func setSelection(identifiers: [String]) {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var map: [String: PHAsset] = [:]
        fetch.enumerateObjects { a, _, _ in map[a.localIdentifier] = a }
        selected = identifiers.compactMap { map[$0] }
    }

    enum QuickRange { case all, days(Int), thisYear }

    func selectQuick(_ range: QuickRange) {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.predicate = NSPredicate(format: "mediaType == %ld || mediaType == %ld",
                                     PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        switch range {
        case .all: break
        case .days(let d):
            let since = Calendar.current.date(byAdding: .day, value: -d, to: Date())!
            opts.predicate = NSPredicate(format: "(mediaType == %ld || mediaType == %ld) AND creationDate >= %@",
                                         PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue,
                                         since as NSDate)
        case .thisYear:
            let since = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date()))!
            opts.predicate = NSPredicate(format: "(mediaType == %ld || mediaType == %ld) AND creationDate >= %@",
                                         PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue,
                                         since as NSDate)
        }
        let fetch = PHAsset.fetchAssets(with: opts)
        var list: [PHAsset] = []
        list.reserveCapacity(fetch.count)
        fetch.enumerateObjects { a, _, _ in list.append(a) }
        selected = list
    }

    func start() {
        guard let target, !selected.isEmpty, !isBusy else { return }
        saveSettings()
        phase = .preparing
        status = "Fotoğraflar hazırlanıyor…"
        totalAssets = selected.count
        sentBytes = 0; doneAssets = 0; skippedAssets = 0; speed = 0; peakSpeed = 0; elapsed = 0
        meter.reset()
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "send") { [weak self] in
            self?.endBackgroundTask()
        }

        let assets = selected
        let includeEdits = self.includeEdits
        let parallel = self.parallel
        let name = DeviceName.current
        let album: String? = putInAlbum ? "Hızlı Aktar – \(name)" : nil

        Thread.detachNewThread { [weak self] in
            let plan = Planner.makePlan(assets, includeEdits: includeEdits)
            let engine = SendEngine(items: plan, endpoint: target.endpoint, parallel: parallel,
                                    deviceName: name, albumTitle: album)
            DispatchQueue.main.async {
                guard let self else { return }
                self.engine = engine
                self.totalAssets = plan.count
                self.phase = .sending
                self.startDate = Date()
                self.startTimer()
            }
            do {
                try engine.run()
                DispatchQueue.main.async { self?.finish(error: nil) }
            } catch {
                DispatchQueue.main.async { self?.finish(error: error) }
            }
        }
    }

    func cancel() { engine?.cancel() }

    func reset() {
        phase = .idle
        status = ""
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let engine else { return }
        let s = engine.snapshot()
        totalBytes = s.total
        sentBytes = s.sent
        doneAssets = s.done
        skippedAssets = s.skipped
        streams = s.streams
        status = s.status
        meter.add(total: s.sent)
        speed = meter.rate
        peakSpeed = max(peakSpeed, speed)
        elapsed = Date().timeIntervalSince(startDate)
    }

    private func finish(error: Error?) {
        tick()
        timer?.invalidate(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        if let error {
            phase = .failed(error.localizedDescription)
        } else {
            phase = .done
        }
        engine = nil
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    var averageSpeed: Double {
        elapsed > 0 ? Double(sentBytes) / elapsed : 0
    }
}

// MARK: - Cihaz adı

enum DeviceName {
    static var current: String {
        get {
            if let s = UserDefaults.standard.string(forKey: "deviceName"), !s.isEmpty { return s }
            let s = "iPhone \(Int.random(in: 10...99))"
            UserDefaults.standard.set(s, forKey: "deviceName")
            return s
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(String(trimmed.prefix(40)), forKey: "deviceName")
        }
    }
}
