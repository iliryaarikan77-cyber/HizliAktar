import SwiftUI
import Photos

// MARK: - Uygulama

@main
struct HizliAktarApp: App {
    @State private var access = LibraryAccess()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(access)
                .preferredColorScheme(.dark)
                .onAppear { access.request() }
        }
    }
}

struct RootView: View {
    @State private var send = SendModel()
    @State private var receive = ReceiveModel()
    @State private var enhance = EnhanceModel()

    var body: some View {
        TabView {
            SendView(model: send)
                .tabItem { Label("Gönder", systemImage: "paperplane.fill") }
            ReceiveView(model: receive)
                .tabItem { Label("Al", systemImage: "tray.and.arrow.down.fill") }
            EnhanceView(model: enhance)
                .tabItem { Label("İyileştir", systemImage: "wand.and.stars") }
        }
        .tint(Color.haAccent)
    }
}

// MARK: - Tema ve ortak parçalar

extension Color {
    static let haAccent = Color(red: 0.22, green: 0.82, blue: 1.0)
    static let haAccent2 = Color(red: 0.56, green: 0.42, blue: 1.0)
    static let haGood = Color(red: 0.3, green: 0.9, blue: 0.55)
}

struct BackgroundGradient: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.09),
                                Color(red: 0.06, green: 0.08, blue: 0.18)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08)))
    }
}

struct StepTitle: View {
    let number: Int
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.footnote.bold())
                .frame(width: 24, height: 24)
                .background(Color.haAccent.opacity(0.2), in: Circle())
                .foregroundStyle(Color.haAccent)
            Text(title).font(.headline)
        }
    }
}

struct BigButton: View {
    let title: String
    let systemImage: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: enabled ? [Color.haAccent, Color.haAccent2] : [.gray.opacity(0.4), .gray.opacity(0.3)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.white)
        }
        .disabled(!enabled)
    }
}

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(AngularGradient(colors: [Color.haAccent, Color.haAccent2, Color.haAccent], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(.callout, design: .rounded).bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AccessBanner: View {
    @Environment(LibraryAccess.self) private var access
    var body: some View {
        Card {
            Label("Fotoğraflara tam erişim gerekli", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.yellow)
            Text("Orijinal dosyaları okuyup kaydedebilmek için Ayarlar → Hızlı Aktar → Fotoğraflar → \"Tam Erişim\" seç.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("İzin İste") { access.request() }.buttonStyle(.bordered)
                Button("Ayarları Aç") { access.openSettings() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct FailedCard: View {
    let message: String
    let retryTitle: String
    let retry: () -> Void
    let back: () -> Void

    var body: some View {
        Card {
            Label("Aktarım durdu", systemImage: "xmark.octagon.fill").font(.headline).foregroundStyle(.red)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button(retryTitle, action: retry).buttonStyle(.borderedProminent)
                Button("Geri", action: back).buttonStyle(.bordered)
            }
        }
    }
}

struct AssetThumb: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if asset.mediaType == .video {
                Image(systemName: "video.fill").font(.system(size: 9)).padding(4).foregroundStyle(.white)
            }
        }
        .task(id: asset.localIdentifier) { image = await load() }
    }

    private func load() async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 168, height: 168),
                                                  contentMode: .aspectFill, options: o) { img, _ in
                cont.resume(returning: img)
            }
        }
    }
}

struct RadarView: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.haAccent.opacity(0.6), lineWidth: 2)
                    .scaleEffect(animate ? 1.0 : 0.2)
                    .opacity(animate ? 0 : 1)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                               value: animate)
            }
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 46))
                .foregroundStyle(Color.haAccent)
        }
        .frame(width: 210, height: 210)
        .onAppear { animate = true }
    }
}

enum TimeFmt {
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s) sn" }
        if s < 3600 { return "\(s / 60) dk \(s % 60) sn" }
        return "\(s / 3600) sa \((s % 3600) / 60) dk"
    }
}

// MARK: - Gönder

struct SendView: View {
    @Bindable var model: SendModel
    @Environment(LibraryAccess.self) private var access
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !access.isFull { AccessBanner() }
                    switch model.phase {
                    case .idle:
                        setup
                    case .preparing, .sending:
                        progress
                    case .done:
                        done
                    case .failed(let msg):
                        FailedCard(message: msg, retryTitle: "Kaldığı yerden devam et",
                                   retry: { model.start() }, back: { model.reset() })
                    }
                }
                .padding()
            }
            .background(BackgroundGradient())
            .navigationTitle("Gönder")
            .sheet(isPresented: $showPicker) {
                PhotoPicker { ids in
                    showPicker = false
                    if !ids.isEmpty { model.setSelection(identifiers: ids) }
                }
                .ignoresSafeArea()
            }
            .onAppear { model.startBrowsing() }
        }
    }

    // Kurulum ekranı
    private var setup: some View {
        VStack(spacing: 16) {
            Card {
                StepTitle(number: 1, title: "Fotoğrafları seç")
                Text(model.selectedSummary)
                    .font(.system(.title3, design: .rounded).bold())
                if !model.selected.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(Array(model.selected.prefix(30)), id: \.localIdentifier) { a in
                                AssetThumb(asset: a)
                            }
                            if model.selected.count > 30 {
                                Text("+\(model.selected.count - 30)")
                                    .font(.footnote.bold())
                                    .frame(width: 56, height: 56)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .frame(height: 56)
                }
                HStack {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Fotoğraflardan Seç", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)

                    Menu {
                        Button("Son 7 gün") { model.selectQuick(.days(7)) }
                        Button("Son 30 gün") { model.selectQuick(.days(30)) }
                        Button("Bu yıl") { model.selectQuick(.thisYear) }
                        Button("Tüm kütüphane") { model.selectQuick(.all) }
                    } label: {
                        Label("Hızlı seçim", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.bordered)

                    if !model.selected.isEmpty {
                        Spacer()
                        Button(role: .destructive) { model.selected = [] } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("İpucu: Seçicide parmağını fotoğrafların üzerinde sürükleyerek yüzlercesini tek hareketle işaretleyebilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card {
                StepTitle(number: 2, title: "Alıcı iPhone'u seç")
                if model.peers.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Aranıyor… Diğer iPhone'da Hızlı Aktar'ı aç, **Al** sekmesinde **Almaya Başla**'ya dokun.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.peers) { p in
                        Button {
                            model.target = p
                        } label: {
                            HStack {
                                Image(systemName: "iphone.gen3")
                                Text(p.name).font(.body.weight(.semibold))
                                Spacer()
                                Image(systemName: model.target?.name == p.name ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.target?.name == p.name ? Color.haAccent : Color.secondary)
                            }
                            .padding(12)
                            .background(Color.white.opacity(model.target?.name == p.name ? 0.10 : 0.04),
                                        in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Card {
                DisclosureGroup("Gelişmiş ayarlar") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("Paralel akış: \(model.parallel)", value: $model.parallel, in: 1...8)
                        Text("Aynı anda kaç dosyanın gideceği. 4 çoğu durumda en hızlısı; yavaşlarsa 2–3 dene.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Düzenlenmiş halleri gönder", isOn: $model.includeEdits)
                        Toggle("Alıcıda ayrı albüme koy", isOn: $model.putInAlbum)
                    }
                    .padding(.top, 8)
                }
                .tint(Color.white)
            }

            BigButton(title: "Gönder", systemImage: "bolt.horizontal.fill",
                      enabled: model.target != nil && !model.selected.isEmpty) {
                model.start()
            }
        }
    }

    // İlerleme ekranı
    private var progress: some View {
        let fraction = model.totalBytes > 0 ? Double(model.sentBytes) / Double(model.totalBytes) : 0
        return VStack(spacing: 18) {
            Card {
                VStack(spacing: 16) {
                    ZStack {
                        ProgressRing(progress: fraction)
                        VStack(spacing: 4) {
                            Text("\(Int(min(1, fraction) * 100))%")
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                            Text(Fmt.speed(model.speed))
                                .font(.headline).foregroundStyle(Color.haAccent)
                        }
                    }
                    .frame(width: 210, height: 210)
                    .frame(maxWidth: .infinity)

                    Text(model.status).font(.subheadline).foregroundStyle(.secondary)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        StatTile(title: "Gönderilen", value: "\(model.doneAssets)/\(max(0, model.totalAssets - model.skippedAssets))")
                        StatTile(title: "Kalan süre", value: Fmt.eta(remaining: max(0, model.totalBytes - model.sentBytes), rate: model.speed))
                        StatTile(title: "Akış", value: "\(model.streams)")
                        StatTile(title: "Aktarılan", value: Fmt.bytes(model.sentBytes))
                        StatTile(title: "Toplam", value: Fmt.bytes(model.totalBytes))
                        StatTile(title: "Atlanan", value: "\(model.skippedAssets)")
                    }
                }
            }
            Text("Aktarım bitene kadar iki telefonda da uygulamayı açık tut.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("İptal", role: .destructive) { model.cancel() }
                .buttonStyle(.bordered)
        }
    }

    // Bitti ekranı
    private var done: some View {
        Card {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.haGood)
                Text("\(model.doneAssets) öğe gönderildi")
                    .font(.title2.bold())
                if model.skippedAssets > 0 {
                    Text("\(model.skippedAssets) öğe zaten karşı telefonda vardı, atlandı.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                    StatTile(title: "Ortalama", value: Fmt.speed(model.averageSpeed))
                    StatTile(title: "Zirve", value: Fmt.speed(model.peakSpeed))
                    StatTile(title: "Süre", value: TimeFmt.duration(model.elapsed))
                }
                Text("Kalite kaybı yok: orijinal dosyalar birebir aktarıldı.")
                    .font(.caption).foregroundStyle(.secondary)
                BigButton(title: "Yeni Aktarım", systemImage: "arrow.counterclockwise") {
                    model.selected = []
                    model.reset()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Al

struct ReceiveView: View {
    @Bindable var model: ReceiveModel
    @Environment(LibraryAccess.self) private var access

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !access.isFull { AccessBanner() }
                    switch model.phase {
                    case .idle:
                        setup
                    case .listening, .receiving:
                        if model.hasSession && model.totalAssets > 0 {
                            receiving
                        } else {
                            listening
                        }
                    case .failed(let msg):
                        FailedCard(message: msg, retryTitle: "Tekrar dene",
                                   retry: { model.start() }, back: { model.stop() })
                    }
                }
                .padding()
            }
            .background(BackgroundGradient())
            .navigationTitle("Al")
        }
    }

    private var setup: some View {
        VStack(spacing: 16) {
            Card {
                Text("Bu iPhone'un görünen adı").font(.headline)
                TextField("Örn. İlirya'nın iPhone'u", text: $model.deviceName)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                Toggle("Zaten olanları atla", isOn: $model.skipDuplicates)
                Text("Açıkken bu telefonda zaten bulunan fotoğraflar tekrar gönderilmez. Aktarım yarıda kalırsa kaldığı yerden devam etmeyi de bu sağlar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            BigButton(title: "Almaya Başla", systemImage: "antenna.radiowaves.left.and.right") {
                model.start()
            }
        }
    }

    private var listening: some View {
        Card {
            VStack(spacing: 14) {
                RadarView()
                Text("Görünür: \(model.deviceName)").font(.title3.bold())
                Text("Gönderen iPhone'da Hızlı Aktar → Gönder ekranında bu ismi seç.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if model.indexing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Kütüphane taranıyor (tekrarları atlamak için)…").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if let m = model.listenerMessage {
                    Text(m).font(.caption).foregroundStyle(.yellow).multilineTextAlignment(.center)
                }
                Button("Durdur", role: .destructive) { model.stop() }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var receiving: some View {
        let expected = max(1, model.expected)
        let fraction = Double(model.committed + model.failed) / Double(expected)
        return VStack(spacing: 16) {
            Card {
                VStack(spacing: 16) {
                    Text(model.isComplete ? "Tamamlandı" : "\(model.senderName) gönderiyor")
                        .font(.headline)
                    ZStack {
                        ProgressRing(progress: model.isComplete ? 1 : fraction)
                        VStack(spacing: 4) {
                            if model.isComplete {
                                Image(systemName: "checkmark").font(.system(size: 54, weight: .bold))
                                    .foregroundStyle(Color.haGood)
                            } else {
                                Text("\(Int(min(1, fraction) * 100))%")
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                                Text(Fmt.speed(model.speed)).font(.headline).foregroundStyle(Color.haAccent)
                            }
                        }
                    }
                    .frame(width: 210, height: 210)
                    .frame(maxWidth: .infinity)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        StatTile(title: "Kaydedilen", value: "\(model.committed)/\(model.expected)")
                        StatTile(title: "Alınan", value: Fmt.bytes(model.receivedBytes))
                        StatTile(title: "Akış", value: "\(model.conns)")
                        StatTile(title: "Atlanan", value: "\(model.skipped)")
                        StatTile(title: "Hatalı", value: "\(model.failed)")
                        StatTile(title: "Kalan süre", value: Fmt.eta(remaining: max(0, model.totalBytes - model.receivedBytes), rate: model.speed))
                    }

                    if model.isComplete {
                        Text("Hepsi Fotoğraflar'a orijinal kalitesinde kaydedildi.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        Text("Uygulamayı açık tut.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Button(model.isComplete ? "Bitir" : "Durdur", role: model.isComplete ? nil : .destructive) {
                model.stop()
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - İyileştir

struct EnhanceView: View {
    @Bindable var model: EnhanceModel
    @Environment(LibraryAccess.self) private var access
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !access.isFull { AccessBanner() }
                    Card {
                        Label("Kaliteyi artır", systemImage: "wand.and.stars").font(.headline)
                        Text("Seçtiğin fotoğrafların iyileştirilmiş bir kopyasını oluşturur: çözünürlüğü 2 katına çıkarır, gürültüyü azaltır, netleştirir ve renkleri dengeler. Orijinaline dokunulmaz.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Not: Yeni detay icat etmez; en çok eski, küçük veya WhatsApp'tan gelmiş fotoğraflarda fark yaratır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Card {
                        Toggle("2× çözünürlük", isOn: $model.options.upscale)
                        Toggle("Gürültü azalt", isOn: $model.options.denoise)
                        Toggle("Netleştir", isOn: $model.options.sharpen)
                        Toggle("Otomatik renk ve ışık", isOn: $model.options.autoColor)
                    }
                    .disabled(model.running)

                    Card {
                        HStack {
                            Text(model.selected.isEmpty ? "Fotoğraf seçilmedi" : "\(model.selected.count) fotoğraf seçildi")
                                .font(.headline)
                            Spacer()
                            Button("Seç") { showPicker = true }
                                .buttonStyle(.bordered)
                                .disabled(model.running)
                        }
                        if model.running || model.finished {
                            ProgressView(value: Double(model.done + model.failed), total: Double(max(1, model.total)))
                            HStack {
                                Text("\(model.done)/\(model.total) tamam").font(.caption)
                                if model.failed > 0 { Text("· \(model.failed) hata").font(.caption).foregroundStyle(.red) }
                                Spacer()
                                Text(model.lastSize).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if model.finished {
                            Text("Kopyalar \"İyileştirilmiş (Hızlı Aktar)\" albümüne kaydedildi.")
                                .font(.caption).foregroundStyle(Color.haGood)
                        }
                    }

                    BigButton(title: model.running ? "İşleniyor…" : "İyileştir",
                              systemImage: "sparkles",
                              enabled: !model.running && !model.selected.isEmpty) {
                        model.run()
                    }
                }
                .padding()
            }
            .background(BackgroundGradient())
            .navigationTitle("İyileştir")
            .sheet(isPresented: $showPicker) {
                PhotoPicker(filter: .images, limit: 100) { ids in
                    showPicker = false
                    if !ids.isEmpty { model.setSelection(identifiers: ids) }
                }
                .ignoresSafeArea()
            }
        }
    }
}
