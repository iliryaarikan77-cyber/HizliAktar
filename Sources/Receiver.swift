import Foundation
import Network
import Photos
import CoreLocation
import UIKit
import Observation

// MARK: - Alım oturumu (bir göndericiden gelen bir aktarım)

final class ReceiveSession {
    let id: String
    let senderName: String
    private let lock = NSLock()

    private(set) var totalBytes: Int64 = 0
    private(set) var totalAssets = 0
    private(set) var skipped = 0
    private(set) var receivedBytes: Int64 = 0
    private(set) var committed = 0
    private(set) var failed = 0
    private(set) var activeConns = 0
    private(set) var hasManifest = false
    var albumID: String?

    init(id: String, senderName: String) {
        self.id = id
        self.senderName = senderName
    }

    func setManifest(totalBytes: Int64, totalAssets: Int, skipped: Int) {
        lock.lock()
        self.totalBytes = totalBytes
        self.totalAssets = totalAssets
        self.skipped = skipped
        self.hasManifest = true
        lock.unlock()
    }
    func addBytes(_ n: Int64) { lock.lock(); receivedBytes += n; lock.unlock() }
    func addCommitted(_ ok: Int, failed f: Int) { lock.lock(); committed += ok; failed += f; lock.unlock() }
    func connDelta(_ d: Int) { lock.lock(); activeConns += d; lock.unlock() }

    func snapshot() -> (total: Int64, received: Int64, assets: Int, skipped: Int, committed: Int, failed: Int, conns: Int, manifest: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (totalBytes, receivedBytes, totalAssets, skipped, committed, failed, activeConns, hasManifest)
    }
}

struct IncomingAsset {
    let msg: AssetBeginMsg
    let dir: URL
    let files: [URL]
    let session: ReceiveSession
}

// MARK: - Kütüphane parmak izi (zaten olanları atlamak için)

enum LibraryIndex {
    static func build() -> Set<String> {
        let fetch = PHAsset.fetchAssets(with: nil)
        var set = Set<String>()
        set.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            autoreleasepool {
                let res = PHAssetResource.assetResources(for: asset)
                guard let main = res.first(where: { $0.type == .photo || $0.type == .video }) ?? res.first else { return }
                set.insert(AssetKey.make(filename: main.originalFilename, date: asset.creationDate,
                                         width: asset.pixelWidth, height: asset.pixelHeight))
            }
        }
        return set
    }
}

// MARK: - Fotoğraflar'a toplu kaydetme

final class CommitQueue {
    private let q = DispatchQueue(label: "ha.commit")
    private var pending: [IncomingAsset] = []
    private var busy = false
    private var timerScheduled = false
    var onCommitted: ((String) -> Void)?   // eklenen fotoğrafın parmak izi

    func add(_ a: IncomingAsset) {
        q.async {
            self.pending.append(a)
            if self.pending.count >= 20 {
                self.flush()
            } else if !self.timerScheduled {
                self.timerScheduled = true
                self.q.asyncAfter(deadline: .now() + 0.4) {
                    self.timerScheduled = false
                    self.flush()
                }
            }
        }
    }

    private func flush() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let batch = pending
        pending = []
        DispatchQueue.global(qos: .userInitiated).async {
            self.commit(batch)
            self.q.async {
                self.busy = false
                if !self.pending.isEmpty { self.flush() }
            }
        }
    }

    private func albums(for batch: [IncomingAsset]) -> [String: PHAssetCollection] {
        let ids = Array(Set(batch.compactMap { $0.session.albumID }))
        guard !ids.isEmpty else { return [:] }
        var map: [String: PHAssetCollection] = [:]
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { c, _, _ in map[c.localIdentifier] = c }
        return map
    }

    private func commit(_ batch: [IncomingAsset]) {
        let albumMap = albums(for: batch)
        let lib = PHPhotoLibrary.shared()

        func perform(_ assets: [IncomingAsset], paired: Bool) throws {
            try lib.performChangesAndWait {
                var byAlbum: [String: [PHObjectPlaceholder]] = [:]
                for a in assets {
                    if let ph = Self.create(a, includePaired: paired), let id = a.session.albumID {
                        byAlbum[id, default: []].append(ph)
                    }
                }
                for (id, placeholders) in byAlbum {
                    if let album = albumMap[id] {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray)
                    }
                }
            }
        }

        func succeeded(_ a: IncomingAsset) {
            a.session.addCommitted(1, failed: 0)
            onCommitted?(a.msg.key)
        }

        do {
            try perform(batch, paired: true)
            batch.forEach(succeeded)
        } catch {
            // Toplu kayıt başarısızsa tek tek dene (sorunlu olan diğerlerini engellemesin)
            for a in batch {
                let filesExist = a.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                guard filesExist else { a.session.addCommitted(0, failed: 1); continue }
                if (try? perform([a], paired: true)) != nil {
                    succeeded(a)
                } else if a.msg.resources.contains(where: { $0.kind == .pairedVideo }),
                          (try? perform([a], paired: false)) != nil {
                    succeeded(a)   // Live Photo eşleşmezse en azından fotoğrafı kaydet
                } else {
                    a.session.addCommitted(0, failed: 1)
                }
            }
        }
        for a in batch { try? FileManager.default.removeItem(at: a.dir) }
    }

    private static func create(_ a: IncomingAsset, includePaired: Bool) -> PHObjectPlaceholder? {
        let req = PHAssetCreationRequest.forAsset()
        for (i, r) in a.msg.resources.enumerated() where i < a.files.count {
            if !includePaired && r.kind == .pairedVideo { continue }
            let o = PHAssetResourceCreationOptions()
            o.originalFilename = r.filename
            o.shouldMoveFile = true      // kopyalamak yerine taşı: büyük videolarda çok daha hızlı
            req.addResource(with: r.kind.phType, fileURL: a.files[i], options: o)
        }
        if let d = a.msg.creationDate { req.creationDate = Date(timeIntervalSince1970: d) }
        if let lat = a.msg.latitude, let lon = a.msg.longitude {
            req.location = CLLocation(latitude: lat, longitude: lon)
        }
        req.isFavorite = a.msg.isFavorite
        return req.placeholderForCreatedAsset
    }
}

// MARK: - Alım motoru

final class ReceiveEngine {
    private var listener: NWListener?
    private let lock = NSLock()
    private var sessions: [String: ReceiveSession] = [:]
    private(set) var latestSession: ReceiveSession?
    private var index = Set<String>()
    private let indexGroup = DispatchGroup()
    private(set) var indexing = false
    private let commits = CommitQueue()
    var skipDuplicates = true
    var onListenerState: ((String?) -> Void)?   // nil = hazır, metin = hata

    init() {
        commits.onCommitted = { [weak self] key in
            guard let self else { return }
            self.lock.lock(); self.index.insert(key); self.lock.unlock()
        }
    }

    var isIndexing: Bool { lock.lock(); defer { lock.unlock() }; return indexing }

    func current() -> ReceiveSession? { lock.lock(); defer { lock.unlock() }; return latestSession }

    func start(name: String) throws {
        stop()
        if skipDuplicates { buildIndex() }

        let l = try NWListener(using: HA.parameters())
        l.service = NWListener.Service(name: name, type: HA.serviceType)
        l.newConnectionHandler = { [weak self] conn in
            Thread.detachNewThread { self?.handle(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onListenerState?(nil)
            case .failed(let e): self?.onListenerState?("Dinleme başlatılamadı: \(e.localizedDescription)")
            case .waiting(let e): self?.onListenerState?("Yerel Ağ izni gerekli olabilir (\(e.localizedDescription))")
            default: break
            }
        }
        l.start(queue: DispatchQueue(label: "ha.listener"))
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func buildIndex() {
        lock.lock(); indexing = true; lock.unlock()
        indexGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let set = LibraryIndex.build()
            self.lock.lock()
            self.index.formUnion(set)
            self.indexing = false
            self.lock.unlock()
            self.indexGroup.leave()
        }
    }

    private func session(id: String, name: String) -> ReceiveSession {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[id] { latestSession = s; return s }
        let s = ReceiveSession(id: id, senderName: name)
        sessions[id] = s
        latestSession = s
        return s
    }

    private func handle(_ conn: NWConnection) {
        let c = BlockingConnection(conn, label: "in-\(UUID().uuidString.prefix(4))")
        var session: ReceiveSession?
        var current: (msg: AssetBeginMsg, dir: URL, files: [URL])?
        var fh: FileHandle?

        defer {
            try? fh?.close()
            if let cur = current { try? FileManager.default.removeItem(at: cur.dir) }   // yarım kalan dosya
            session?.connDelta(-1)
            c.cancel()
        }

        do {
            try c.start()
            let (t, body) = try c.readFrame(timeout: 30)
            guard t == .hello, let hello = try? JSONDecoder().decode(HelloMsg.self, from: body) else { return }
            let s = self.session(id: hello.sessionID, name: hello.deviceName)
            session = s
            s.connDelta(1)

            if hello.connIndex == 0 {
                let (t2, b2) = try c.readFrame(timeout: 30)
                guard t2 == .manifest, let m = try? JSONDecoder().decode(ManifestMsg.self, from: b2) else { return }
                var skip: [Int] = []
                if skipDuplicates {
                    indexGroup.wait()
                    lock.lock()
                    for (i, k) in m.keys.enumerated() where index.contains(k) { skip.append(i) }
                    lock.unlock()
                }
                if let title = m.albumTitle, s.albumID == nil {
                    s.albumID = Albums.ensure(title)
                }
                s.setManifest(totalBytes: m.totalBytes, totalAssets: m.keys.count, skipped: skip.count)
                try c.send(encodeJSONFrame(.skipList, SkipMsg(skip: skip)))
            }

            let fm = FileManager.default
            while true {
                let finished: Bool = try autoreleasepool {
                    let (type, payload) = try c.readFrame(timeout: 1800)   // gönderici iCloud'dan orijinal indirirken uzun süre sessiz kalabilir
                    switch type {
                    case .assetBegin:
                        guard let msg = try? JSONDecoder().decode(AssetBeginMsg.self, from: payload) else { throw ProtoError.badFrame }
                        let dir = fm.temporaryDirectory.appendingPathComponent("recv-\(UUID().uuidString)", isDirectory: true)
                        var files: [URL] = []
                        for (i, r) in msg.resources.enumerated() {
                            let sub = dir.appendingPathComponent("\(i)", isDirectory: true)
                            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                            let safe = r.filename.replacingOccurrences(of: "/", with: "_")
                            files.append(sub.appendingPathComponent(safe.isEmpty ? "file" : safe))
                        }
                        current = (msg, dir, files)

                    case .resourceBegin:
                        guard let cur = current, let idx = payload.first, Int(idx) < cur.files.count else { throw ProtoError.badFrame }
                        let url = cur.files[Int(idx)]
                        fm.createFile(atPath: url.path, contents: nil)
                        fh = try FileHandle(forWritingTo: url)

                    case .data:
                        guard let h = fh else { throw ProtoError.badFrame }
                        try h.write(contentsOf: payload)
                        s.addBytes(Int64(payload.count))

                    case .resourceEnd:
                        try fh?.close()
                        fh = nil

                    case .assetEnd:
                        guard let cur = current else { throw ProtoError.badFrame }
                        commits.add(IncomingAsset(msg: cur.msg, dir: cur.dir, files: cur.files, session: s))
                        current = nil

                    case .done:
                        return true

                    default:
                        throw ProtoError.badFrame
                    }
                    return false
                }
                if finished { break }
            }
        } catch {
            // bağlantı koptu; gönderici diğer akışlardan / yeniden bağlanarak devam eder
        }
    }
}

// MARK: - Al ekranının modeli

@Observable
final class ReceiveModel {
    enum Phase: Equatable { case idle, listening, receiving, failed(String) }

    var phase: Phase = .idle
    var deviceName: String = DeviceName.current
    var skipDuplicates: Bool = UserDefaults.standard.object(forKey: "skipDuplicates") as? Bool ?? true
    var listenerMessage: String?

    var senderName = ""
    var totalAssets = 0
    var skipped = 0
    var committed = 0
    var failed = 0
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var conns = 0
    var speed: Double = 0
    var indexing = false
    var hasSession = false

    @ObservationIgnored private let engine = ReceiveEngine()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let meter = SpeedMeter()
    @ObservationIgnored private var lastSessionID: String?

    var expected: Int { max(0, totalAssets - skipped) }
    var isComplete: Bool { hasSession && totalAssets > 0 && committed + failed >= expected && conns == 0 }

    func start() {
        DeviceName.current = deviceName
        deviceName = DeviceName.current
        UserDefaults.standard.set(skipDuplicates, forKey: "skipDuplicates")
        engine.skipDuplicates = skipDuplicates
        engine.onListenerState = { [weak self] msg in
            DispatchQueue.main.async { self?.listenerMessage = msg }
        }
        do {
            try engine.start(name: deviceName)
            phase = .listening
            UIApplication.shared.isIdleTimerDisabled = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        engine.stop()
        timer?.invalidate(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .idle
        hasSession = false
        lastSessionID = nil
    }

    private func tick() {
        indexing = engine.isIndexing
        guard let s = engine.current() else { return }
        if s.id != lastSessionID {
            lastSessionID = s.id
            meter.reset()
        }
        let snap = s.snapshot()
        hasSession = true
        senderName = s.senderName
        totalBytes = snap.total
        receivedBytes = snap.received
        totalAssets = snap.assets
        skipped = snap.skipped
        committed = snap.committed
        failed = snap.failed
        conns = snap.conns
        meter.add(total: snap.received)
        speed = meter.rate
        if phase == .listening || phase == .receiving {
            phase = conns > 0 ? .receiving : .listening
        }
    }
}
