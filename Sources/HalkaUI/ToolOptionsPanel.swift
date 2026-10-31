import AppKit
import HalkaCore
import SwiftUI

/// Panelin bilmesi gerekenler; süre ve sayfa sayısı panel açılmadan okunur.
public struct ToolContext: Sendable {
    public let tool: Tool
    public let files: [URL]
    public let duration: Double?
    public let pageCount: Int?

    public init(tool: Tool, files: [URL], duration: Double? = nil, pageCount: Int? = nil) {
        self.tool = tool
        self.files = files
        self.duration = duration
        self.pageCount = pageCount
    }
}

/// Aracın ayarlarını soran küçük pencere. Varsayılanlar hazır: Enter "Uygula", Esc "Vazgeç".
///
/// Pencere hemen açılır; dosyalar başka bir uygulamadan geliyorsa (Fotoğraflar, iCloud'dan inmesi gerekebilir)
/// `prepare` bitene kadar bekleme gösterir. Sonuç hazırlanan bağlam ve seçilen ayarlar.
@MainActor
public enum ToolOptionsPrompt {
    public static func ask(tool: Tool, names: [URL], waitingMessage: String,
                           prepare: @escaping @MainActor () async throws -> ToolContext) async -> (ToolContext, ToolOptions)? {
        await withCheckedContinuation { continuation in
            // Sürükleme biterken öndeki uygulama Finder/Fotoğraflar; Halka etkin değil. NSPanel varsayılan olarak
            // uygulama etkin değilken gizlenir (`hidesOnDeactivate`) ve macOS 14+ `activate()`'i sadece bir istek
            // sayar: panel, Halka bir şekilde öne gelene kadar görünmüyordu. Etkinleştirmeyen panel klavyeyi de
            // uygulamayı öne almadan alır.
            let window = KeyPanel(contentRect: .zero,
                                  styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            window.hidesOnDeactivate = false
            let delegate = CloseDelegate()
            var finished = false
            let finish: ((ToolContext, ToolOptions)?) -> Void = { answer in
                guard !finished else { return }
                finished = true
                window.delegate = nil
                window.close()
                continuation.resume(returning: answer)
                _ = delegate
            }
            delegate.onClose = { finish(nil) }
            let root = PreparingView(tool: tool, names: names, waitingMessage: waitingMessage, prepare: prepare, done: finish)
            window.contentViewController = NSHostingController(rootView: root)
            window.title = tool.label
            window.titlebarAppearsTransparent = true
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.delegate = delegate
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.center()
            window.orderFrontRegardless()
            window.makeKey()
        }
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class CloseDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// Bağlam hazırlanana kadar bekleme, sonra ayarlar; hazırlık başarısızsa hata.
struct PreparingView: View {
    let tool: Tool
    let names: [URL]
    let waitingMessage: String
    let prepare: @MainActor () async throws -> ToolContext
    let done: ((ToolContext, ToolOptions)?) -> Void

    @State private var context: ToolContext?
    @State private var failure: String?

    var body: some View {
        Group {
            if let context {
                ToolOptionsView(context: context) { options in done(options.map { (context, $0) }) }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(names.count == 1 ? names[0].lastPathComponent : L("\(names.count) files", "\(names.count) dosya"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(waitingMessage).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button(L("Cancel", "Vazgeç")) { done(nil) }.keyboardShortcut(.cancelAction)
                        Button(L("Apply", "Uygula")) {}.keyboardShortcut(.defaultAction).disabled(true)
                    }
                }
                .padding(18)
                .padding(.top, 8)
                .frame(width: 360)
            }
        }
        .task {
            do { context = try await prepare() } catch is CancellationError {} catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct ToolOptionsView: View {
    let context: ToolContext
    let done: (ToolOptions?) -> Void
    /// Starting crop selection; only the README images set it.
    var previewCrop: CropRect?

    @State private var level: CompressLevel = .medium
    @State private var estimate: SizeEstimate.Result?
    @State private var estimating = false
    @State private var resizeByPercent = false
    @State private var percent = 50
    @State private var longEdge = 1920
    @State private var aspect: Aspect = .free
    @State private var cropRect = CropRect(x: 0, y: 0, width: 1, height: 1)
    @State private var preview: CGImage?
    @State private var rotation = 90
    @State private var horizontal = true
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var frameTime = 0.0
    @State private var filmstrip: [CGImage] = []
    @State private var parts = 2
    @State private var order: [URL] = []
    @State private var pages = ""
    @State private var password = ""
    @State private var confirmation = ""

    enum Aspect: Hashable, CaseIterable {
        case free, square, portrait, classic, photo, wide, story
        var ratio: Double? {
            switch self {
            case .free: nil
            case .square: 1
            case .portrait: 4.0 / 5
            case .classic: 4.0 / 3
            case .photo: 3.0 / 2
            case .wide: 16.0 / 9
            case .story: 9.0 / 16
            }
        }
        var label: String {
            switch self {
            case .free: L("Free", "Serbest")
            case .square: "1:1"
            case .portrait: "4:5"
            case .classic: "4:3"
            case .photo: "3:2"
            case .wide: "16:9"
            case .story: "9:16"
            }
        }
    }

    private var file: URL { context.files[0] }
    private var duration: Double { context.duration ?? 0 }

    private var subtitle: String {
        context.files.count == 1 ? file.lastPathComponent : L("\(context.files.count) files", "\(context.files.count) dosya")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            content
            HStack {
                Spacer()
                Button(L("Cancel", "Vazgeç")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(L("Apply", "Uygula")) { done(options) }.keyboardShortcut(.defaultAction).disabled(options == nil)
            }
        }
        .padding(18)
        .padding(.top, 8)
        .frame(width: wide ? 400 : 360)
        .onAppear {
            order = context.files
            end = duration
            frameTime = duration / 2
            if let count = context.pageCount { pages = count > 1 ? "1-\(count)" : "1" }
        }
        .task { await loadPreviews() }
    }

    private var wide: Bool { [.crop, .trim, .frame].contains(context.tool.id) }

    private func loadPreviews() async {
        switch context.tool.id {
        case .crop:
            preview = await Previews.image(of: file, at: duration / 2)
            if let previewCrop { cropRect = previewCrop }
        case .trim, .frame:
            guard duration > 0 else { return }
            filmstrip = await Previews.filmstrip(of: file, duration: duration, count: 8)
            if context.tool.id == .frame { preview = await Previews.image(of: file, at: frameTime, maxEdge: 700) }
        default:
            break
        }
    }

    @ViewBuilder private var content: some View {
        switch context.tool.id {
        case .compress:
            Picker(L("Level", "Seviye"), selection: $level) {
                ForEach(CompressLevel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(compressHint).font(.caption).foregroundStyle(.secondary)
            if context.files.count == 1 { estimateView }
        case .resize:
            Picker("", selection: $resizeByPercent) {
                Text(L("Long edge", "Uzun kenar")).tag(false)
                Text(L("Percent", "Yüzde")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            if resizeByPercent {
                Picker(L("Percent", "Yüzde"), selection: $percent) {
                    ForEach([25, 50, 75], id: \.self) { Text("%\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            } else {
                HStack {
                    Picker(L("Long edge", "Uzun kenar"), selection: $longEdge) {
                        ForEach([3840, 2560, 1920, 1280, 800], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    TextField("px", value: $longEdge, format: .number).frame(width: 70)
                }
                Text(L("Smaller images are never upscaled.", "Daha küçük görüntüler büyütülmez.")).font(.caption).foregroundStyle(.secondary)
            }
        case .crop:
            Picker(L("Ratio", "Oran"), selection: $aspect) {
                ForEach(Aspect.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: aspect) { _, new in
                guard let ratio = new.ratio, let preview else { return }
                cropRect = .centred(aspect: ratio, imageAspect: Double(preview.width) / Double(preview.height))
            }
            if let preview {
                CropEditor(image: preview, rect: $cropRect, aspect: aspect.ratio)
                    .frame(maxWidth: .infinity)
            } else {
                loading
            }
            Text(L("Drag the frame; resize it from the corners.", "Çerçeveyi sürükleyin, köşelerinden boyutlandırın.")).font(.caption).foregroundStyle(.secondary)
        case .rotate:
            Picker("", selection: $rotation) {
                Text(L("90° right", "90° sağa")).tag(90)
                Text(L("90° left", "90° sola")).tag(270)
                Text("180°").tag(180)
            }
            .pickerStyle(.segmented).labelsHidden()
        case .flip:
            Picker("", selection: $horizontal) {
                Text(L("Horizontal (mirror)", "Yatay (ayna)")).tag(true)
                Text(L("Vertical", "Dikey")).tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
        case .trim:
            if duration > 0 {
                Filmstrip(frames: filmstrip, duration: duration, start: $start, end: $end, playhead: nil)
                HStack {
                    timeField(L("Start", "Başlangıç"), $start)
                    Spacer()
                    Text(L("Length \(Self.format(max(end - start, 0)))", "Süre \(Self.format(max(end - start, 0)))")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    timeField(L("End", "Bitiş"), $end)
                }
            } else {
                Text(L("Could not read the duration.", "Süre okunamadı.")).foregroundStyle(.secondary)
            }
        case .frame:
            if let preview {
                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                loading
            }
            if duration > 0 {
                Filmstrip(frames: filmstrip, duration: duration, start: .constant(0), end: .constant(duration),
                          playhead: $frameTime)
                    .onChange(of: frameTime) { _, time in
                        Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            guard time == frameTime else { return }
                            preview = await Previews.image(of: file, at: time, maxEdge: 700)
                        }
                    }
                HStack {
                    timeField(L("Time", "An"), $frameTime)
                    Spacer()
                }
            }
        case .split:
            Stepper(L("\(parts) equal parts", "\(parts) eşit parça"), value: $parts, in: 2...20)
            Text(L("Split at keyframes without re-encoding; cuts may shift by a few frames.", "Anahtar karelerden bölünür, yeniden kodlanmaz; parça sınırları birkaç kare kayabilir."))
                .font(.caption).foregroundStyle(.secondary)
        case .merge:
            Text(L("Merged from top to bottom.", "Yukarıdan aşağı sırayla birleştirilir.")).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(Array(order.enumerated()), id: \.element) { index, url in
                    HStack {
                        Text("\(index + 1). \(url.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(index == order.count - 1)
                    }
                }
            }
        case .extractPages:
            TextField(L("e.g. 1-3, 5", "ör. 1-3, 5"), text: $pages)
            if let count = context.pageCount {
                Text(L("The document has \(count) pages. Separate ranges with commas; “4-” means to the end.", "Belge \(count) sayfa. Aralıklar virgülle; “4-” sona kadar."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .protect:
            SecureField(L("Password", "Parola"), text: $password)
            SecureField(L("Password (again)", "Parola (tekrar)"), text: $confirmation)
            if !password.isEmpty && !PDFTools.isValidPassword(password) {
                Label(L("Only plain ASCII characters work in PDF passwords.", "Türkçe karakter (ç, ğ, ı, ö, ş, ü) kullanılamaz; PDF desteklemiyor."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text(L("This password is asked when the PDF opens. A forgotten password cannot be recovered.", "PDF açılırken bu parola sorulur. Parolayı unutursanız geri alınamaz."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .unprotect:
            SecureField(L("Current password", "Mevcut parola"), text: $password)
        case .strip, .normalize, .extractAudio, .removeAudio, .removeBackground, .extractText:
            EmptyView()
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("Preparing preview…", "Önizleme hazırlanıyor…")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    @ViewBuilder private var estimateView: some View {
        HStack(spacing: 6) {
            if let estimate {
                let change = 1 - Double(estimate.after) / Double(max(estimate.before, 1))
                Text(L("\(Self.size(estimate.before)) → about \(Self.size(estimate.after))", "\(Self.size(estimate.before)) → yaklaşık \(Self.size(estimate.after))"))
                Text(change > 0 ? L("\(Int((change * 100).rounded()))% smaller", "%\(Int((change * 100).rounded())) küçük") : L("no smaller", "küçülmüyor"))
                    .foregroundStyle(change > 0.05 ? .green : .orange)
            } else if estimating {
                ProgressView().controlSize(.mini)
                Text(L("Estimating…", "Tahmin ediliyor…")).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task(id: level) {
            estimating = true
            estimate = nil
            estimate = await SizeEstimate.compress(file, level: level)
            estimating = false
        }
    }

    private func timeField(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("0:00", text: Binding(
                get: { Self.format(value.wrappedValue) },
                set: { if let seconds = Self.parse($0) { value.wrappedValue = min(max(seconds, 0), duration) } }))
                .frame(width: 70)
        }
    }

    private var compressHint: String {
        switch level {
        case .light: L("Nearly the same quality, somewhat smaller.", "Kalite neredeyse aynı, boyut biraz küçülür.")
        case .medium: L("Visually lossless; large images and videos are scaled down.", "Gözle fark edilmez; büyük görüntü ve videolar küçültülür.")
        case .strong: L("The smallest file, for sharing.", "En küçük dosya; paylaşmak için.")
        }
    }

    /// Geçersizse `nil` (Uygula kapalı).
    private var options: ToolOptions? {
        switch context.tool.id {
        case .compress: return .compress(level)
        case .resize: return resizeByPercent ? .resize(.percent(percent)) : (longEdge > 0 ? .resize(.longEdge(longEdge)) : nil)
        case .crop: return preview == nil || cropRect.isWhole ? nil : .crop(cropRect)
        case .rotate: return .rotate(rotation)
        case .flip: return .flip(horizontal: horizontal)
        case .trim: return end - start >= 0.1 ? .trim(start: start, end: end) : nil
        case .frame: return .frame(at: frameTime)
        case .split: return .split(.parts(parts))
        case .merge: return .merge(order)
        case .extractPages:
            guard let count = context.pageCount, PageRange.parse(pages, pageCount: count) != nil else { return nil }
            return .pages(pages)
        case .protect: return PDFTools.isValidPassword(password) && password == confirmation ? .password(password) : nil
        case .unprotect: return password.isEmpty ? nil : .password(password)
        case .strip, .normalize, .extractAudio, .removeAudio, .removeBackground, .extractText: return ToolOptions.none
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }

    /// "1:05.5", "65.5", "1:02:03" → saniye.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    static func format(_ seconds: Double) -> String {
        let whole = Int(seconds), fraction = seconds - Double(whole)
        let base = whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
        return fraction >= 0.05 ? base + String(format: ".%d", Int((fraction * 10).rounded(.down))) : base
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Görüntünün üzerinde sürüklenen, köşelerinden boyutlanan kırpma çerçevesi. `rect` görüntüye oranla.
struct CropEditor: View {
    let image: CGImage
    @Binding var rect: CropRect
    /// Genişlik / yükseklik (piksel); `nil` serbest.
    let aspect: Double?

    @State private var startRect: CropRect?
    private let minimum = 0.05

    private var imageAspect: Double { Double(image.width) / Double(image.height) }

    var body: some View {
        let box = CGSize(width: 364, height: 260)
        let size = imageAspect > box.width / box.height
            ? CGSize(width: box.width, height: box.width / imageAspect)
            : CGSize(width: box.height * imageAspect, height: box.height)
        let frame = CGRect(x: rect.x * size.width, y: rect.y * size.height,
                           width: rect.width * size.width, height: rect.height * size.height)
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .gesture(DragGesture().onChanged { value in
                    let base = startRect ?? rect
                    startRect = base
                    rect.x = min(max(base.x + value.translation.width / size.width, 0), 1 - base.width)
                    rect.y = min(max(base.y + value.translation.height / size.height, 0), 1 - base.height)
                }.onEnded { _ in startRect = nil })
            ForEach(0..<4, id: \.self) { corner in
                let point = CGPoint(x: corner % 2 == 0 ? frame.minX : frame.maxX, y: corner < 2 ? frame.minY : frame.maxY)
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .shadow(radius: 1)
                    .offset(x: point.x - 6, y: point.y - 6)
                    .gesture(DragGesture(coordinateSpace: .named("kırpma")).onChanged { value in
                        resize(corner: corner, to: CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
                    })
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "kırpma")
        .clipped()
    }

    /// Karşı köşe sabit kalır; oran kilitliyse yükseklik genişliğe göre.
    private func resize(corner: Int, to point: CGPoint) {
        let anchorX = corner % 2 == 0 ? rect.x + rect.width : rect.x
        let anchorY = corner < 2 ? rect.y + rect.height : rect.y
        let px = min(max(point.x, 0), 1), py = min(max(point.y, 0), 1)
        var width = max(abs(px - anchorX), minimum)
        var height = max(abs(py - anchorY), minimum)
        if let aspect {
            // Oran piksel cinsinden; normalleştirilmiş yükseklik = genişlik × görüntü oranı / oran.
            height = width * imageAspect / aspect
            let maxHeight = corner < 2 ? anchorY : 1 - anchorY
            if height > maxHeight {
                height = maxHeight
                width = height * aspect / imageAspect
            }
            let maxWidth = corner % 2 == 0 ? anchorX : 1 - anchorX
            if width > maxWidth {
                width = maxWidth
                height = width * imageAspect / aspect
            }
        }
        rect = CropRect(x: corner % 2 == 0 ? anchorX - width : anchorX,
                        y: corner < 2 ? anchorY - height : anchorY,
                        width: min(width, 1), height: min(height, 1))
    }
}

/// Video karelerinden şerit; iki tutamaçla aralık ya da tek tutamaçla an seçilir.
struct Filmstrip: View {
    let frames: [CGImage]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// Doluysa aralık değil tek an seçilir (kare al).
    let playhead: Binding<Double>?

    private let height = 54.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (time: Double) in duration > 0 ? time / duration * width : 0 }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                        Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: width / Double(max(frames.count, 1)), height: height).clipped()
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 5))

                if let playhead {
                    Rectangle().fill(Color.accentColor).frame(width: 3, height: height + 8)
                        .offset(x: x(playhead.wrappedValue) - 1.5, y: -4)
                } else {
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(x(start), 0), height: height)
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(width - x(end), 0), height: height)
                        .offset(x: x(end))
                    RoundedRectangle(cornerRadius: 4).stroke(Color.yellow, lineWidth: 3)
                        .frame(width: max(x(end) - x(start), 2), height: height)
                        .offset(x: x(start))
                    handle.offset(x: x(start) - 5).gesture(drag(width) { start = min($0, end - 0.1) })
                    handle.offset(x: x(end) - 5).gesture(drag(width) { end = max($0, start + 0.1) })
                }
            }
            .contentShape(Rectangle())
            .gesture(playhead.map { binding in drag(width) { binding.wrappedValue = $0 } })
            .coordinateSpace(name: "şerit")
        }
        .frame(height: height)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.yellow).frame(width: 10, height: height)
    }

    private func drag(_ width: Double, _ set: @escaping (Double) -> Void) -> some Gesture {
        // Konum şeride göre; tutamacın kendi koordinatı kullanılırsa tutamaç başa atlar.
        DragGesture(minimumDistance: 0, coordinateSpace: .named("şerit")).onChanged { value in
            set(min(max(value.location.x / width * duration, 0), duration))
        }
    }
}
