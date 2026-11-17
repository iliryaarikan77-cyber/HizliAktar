import Foundation
import Network
import Photos

// MARK: - Sabitler

enum HA {
    static let serviceType = "_hizliaktar._tcp"
    static let chunkSize = 1 << 20          // 1 MB veri parçaları
    static let maxInflightSends = 24        // bağlantı başına uçuştaki parça sayısı
    static let defaultParallel = 4

    /// Hem gönderici hem alıcı aynı ayarları kullanır: TCP, eşler arası (AWDL) açık.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = false
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 15
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true          // iki iPhone arasında doğrudan Wi‑Fi (AirDrop'un kullandığı bağlantı)
        p.serviceClass = .responsiveData
        return p
    }
}

// MARK: - Çerçeve (frame) protokolü
// [1 bayt tür][4 bayt uzunluk, big‑endian][içerik]

enum FrameType: UInt8 {
    case hello = 1
    case manifest = 2
    case skipList = 3
    case assetBegin = 4
    case resourceBegin = 5
    case data = 6
    case resourceEnd = 7
    case assetEnd = 8
    case done = 9
}

enum ProtoError: LocalizedError {
    case closed
    case badFrame
    case timeout
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "Bağlantı kapandı"
        case .badFrame: return "Bozuk veri alındı"
        case .timeout: return "Bağlantı zaman aşımına uğradı"
        case .unexpected(let s): return s
        }
    }
}

func encodeFrame(_ type: FrameType, _ payload: Data = Data()) -> Data {
    var d = Data(capacity: 5 + payload.count)
    d.append(type.rawValue)
    let len = UInt32(payload.count)
    d.append(UInt8((len >> 24) & 0xff))
    d.append(UInt8((len >> 16) & 0xff))
    d.append(UInt8((len >> 8) & 0xff))
    d.append(UInt8(len & 0xff))
    d.append(payload)
    return d
}

func encodeJSONFrame<T: Encodable>(_ type: FrameType, _ value: T) -> Data {
    let payload = (try? JSONEncoder().encode(value)) ?? Data()
    return encodeFrame(type, payload)
}

// MARK: - Mesajlar

struct HelloMsg: Codable {
    let sessionID: String
    let deviceName: String
    let connIndex: Int
}

struct ManifestMsg: Codable {
    let keys: [String]          // her fotoğrafın parmak izi (tekrar kontrolü için)
    let totalBytes: Int64
    let albumTitle: String?
}

struct SkipMsg: Codable {
    let skip: [Int]             // alıcıda zaten olan fotoğrafların sırası
}

enum ResourceKind: Int, Codable {
    case photo = 1, video = 2, audio = 3, alternatePhoto = 4, pairedVideo = 9

    var phType: PHAssetResourceType {
        switch self {
        case .photo: return .photo
        case .video: return .video
        case .audio: return .audio
        case .alternatePhoto: return .alternatePhoto
        case .pairedVideo: return .pairedVideo
        }
    }
}

struct ResourceInfo: Codable {
    let kind: ResourceKind
    let filename: String
    let size: Int64
}

struct AssetBeginMsg: Codable {
    let index: Int
    let key: String
    let creationDate: Double?
    let latitude: Double?
    let longitude: Double?
    let isFavorite: Bool
    let resources: [ResourceInfo]
}

// MARK: - Parmak izi (tekrar atlama / kaldığı yerden devam)

enum AssetKey {
    static func make(filename: String, date: Date?, width: Int, height: Int) -> String {
        let base = (filename as NSString).deletingPathExtension.lowercased()
        let t = Int((date ?? .distantPast).timeIntervalSince1970)
        return "\(base)|\(t)|\(width)x\(height)"
    }
}

// MARK: - Engelleyen (blocking) bağlantı sarmalayıcısı
// Her işçi kendi iş parçacığında çalışır; bu sayede kod sade kalır,
// ağ yavaşsa gönderim otomatik olarak bekler (backpressure).

final class BlockingConnection {
    let conn: NWConnection
    private let queue: DispatchQueue
    private let inflight = DispatchSemaphore(value: HA.maxInflightSends)
    private let lock = NSLock()
    private var _error: Error?
    private var readyContinuation: DispatchSemaphore?

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return _error
    }

    private func setError(_ e: Error) {
        lock.lock()
        if _error == nil { _error = e }
        lock.unlock()
    }

    init(_ conn: NWConnection, label: String) {
        self.conn = conn
        self.queue = DispatchQueue(label: "ha.conn.\(label)", qos: .userInitiated)
    }

    /// Bağlantıyı başlatır ve hazır olana kadar bekler.
    func start(timeout: TimeInterval = 20) throws {
        let ready = DispatchSemaphore(value: 0)
        var signaled = false
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if !signaled { signaled = true; ready.signal() }
            case .failed(let e):
                self?.setError(e)
                if !signaled { signaled = true; ready.signal() }
            case .cancelled:
                self?.setError(ProtoError.closed)
                if !signaled { signaled = true; ready.signal() }
            case .waiting(let e):
                // Eş bulunamadıysa bir süre bekler; zaman aşımına bırakıyoruz.
                _ = e
            default:
                break
            }
        }
        conn.start(queue: queue)
        if ready.wait(timeout: .now() + timeout) == .timedOut {
            conn.cancel()
            throw ProtoError.timeout
        }
        if let e = error { throw e }
    }

    /// Zaten başlatılmış (listener'dan gelen) bağlantı için.
    func adoptStarted() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let e): self?.setError(e)
            case .cancelled: self?.setError(ProtoError.closed)
            default: break
            }
        }
    }

    func send(_ data: Data) throws {
        if let e = error { throw e }
        if inflight.wait(timeout: .now() + 60) == .timedOut { throw ProtoError.timeout }
        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            if let err { self?.setError(err) }
            self?.inflight.signal()
        })
    }

    /// Gönderilen her şeyin işletim sistemine teslim edilmesini bekler.
    func flush() throws {
        var taken = 0
        for _ in 0..<HA.maxInflightSends {
            if inflight.wait(timeout: .now() + 60) == .timedOut { break }
            taken += 1
        }
        for _ in 0..<taken { inflight.signal() }
        if taken < HA.maxInflightSends { throw ProtoError.timeout }
        if let e = error { throw e }
    }

    private func receiveExactly(_ n: Int, timeout: TimeInterval) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var rerr: Error?
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, err in
            if let err { rerr = err }
            else if let data, data.count == n { result = data }
            else if isComplete { rerr = ProtoError.closed }
            else { rerr = ProtoError.badFrame }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { throw ProtoError.timeout }
        if let rerr { setError(rerr); throw rerr }
        guard let result else { throw ProtoError.badFrame }
        return result
    }

    func readFrame(timeout: TimeInterval = 120) throws -> (FrameType, Data) {
        let header = [UInt8](try receiveExactly(5, timeout: timeout))
        guard let type = FrameType(rawValue: header[0]) else { throw ProtoError.badFrame }
        let len = (Int(header[1]) << 24) | (Int(header[2]) << 16) | (Int(header[3]) << 8) | Int(header[4])
        if len == 0 { return (type, Data()) }
        if len > 64 << 20 { throw ProtoError.badFrame }
        let body = try receiveExactly(len, timeout: timeout)
        return (type, body)
    }

    func cancel() { conn.cancel() }
}

// MARK: - Hız ölçer

final class SpeedMeter {
    private var samples: [(t: TimeInterval, bytes: Int64)] = []
    private let window: TimeInterval = 3

    func add(total: Int64) {
        let now = Date().timeIntervalSince1970
        samples.append((now, total))
        samples.removeAll { now - $0.t > window }
    }

    /// bayt/saniye
    var rate: Double {
        guard let first = samples.first, let last = samples.last, last.t - first.t > 0.3 else { return 0 }
        return Double(last.bytes - first.bytes) / (last.t - first.t)
    }

    func reset() { samples.removeAll() }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    static func speed(_ bps: Double) -> String {
        let mb = bps / 1_000_000
        return String(format: "%.1f MB/sn", mb)
    }
    static func eta(remaining: Int64, rate: Double) -> String {
        guard rate > 1 else { return "—" }
        let s = Int(Double(remaining) / rate)
        if s < 60 { return "\(s) sn" }
        return "\(s / 60) dk \(s % 60) sn"
    }
}
