import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor final class MatchModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var selected: UInt32 = 0
    @Published var tuning = Tuning()
    @Published var enabled = false
    @Published var message = "비교 화면을 열고, 외장 모니터의 흰색부터 맞춰보세요."
    @Published var failed = false
    @Published var uncertain = false
    @Published var photoSession: String?
    @Published var photoBusy = false
    @Published var photoPreview = false
    @Published var photoSeconds = 0
    @Published var photoStrength = 0.25
    var photoFit: PhotoFitResult?
    @Published var photoMessage = "아이폰 사진 한 장으로 흰색 균형과 중간톤을 맞춥니다. 사진은 이 Mac에서만 분석합니다."
    var photoOriginal = Tuning()
    var photoWasEnabled = false
    var photoDisplayID: UInt32 = 0
    var photoDisplayIdentity = ""
    var photoBaseline: GammaTable?
    var photoTimer: Timer?
    let engine = GammaEngine()
    var patterns: [NSWindow] = []
    var observations: [NSObjectProtocol] = []
    var configuration = ""
    var current: DisplayInfo? { displays.first { $0.id == selected } }
    var external: [DisplayInfo] { displays.filter { !$0.builtIn } }
    var key: String { "tuning." + (current?.stableID ?? "none") }

    init() {
        refresh()
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.environmentChanged() }
        })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopForSleep() }
        })
    }
    func report(_ text: String, error: Bool = false) { failed = error; message = text; if error { uncertain = true } }
    func refresh() {
        displays = engine.enumerate()
        configuration = screenConfiguration()
        if !external.contains(where: { $0.id == selected }) { selected = external.first?.id ?? 0; load() }
    }
    func screenConfiguration() -> String {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let mode = CGDisplayCopyDisplayMode(id)
            return "\(id):\(screen.frame):\(screen.backingScaleFactor):\(mode?.pixelWidth ?? 0):\(mode?.pixelHeight ?? 0):\(mode?.refreshRate ?? 0):\(CGDisplayIsInMirrorSet(id))"
        }.sorted().joined(separator: "|")
    }
    func stopForSleep() {
        invalidatePhoto()
        let errors = engine.restoreAll()
        enabled = false
        uncertain = !errors.isEmpty
        report(errors.isEmpty ? "잠자기 전에 원래 색감으로 복원했습니다. 돌아오면 다시 적용하세요." : errors.joined(separator: "\n"), error: !errors.isEmpty)
    }
    func environmentChanged() {
        guard screenConfiguration() != configuration else { return }
        invalidatePhoto()
        closePatterns()
        let errors = engine.restoreAll()
        enabled = false
        uncertain = !errors.isEmpty
        refresh()
        report(errors.isEmpty ? "화면 연결 또는 설정이 바뀌어 보정을 중지했습니다. 화면을 확인한 뒤 다시 적용하세요." : errors.joined(separator: "\n"), error: !errors.isEmpty)
    }
    func select(_ id: UInt32) {
        guard photoSession == nil else { return }
        guard id != selected else { return }
        do {
            if enabled { try engine.restore(displayID: selected) }
            enabled = false; uncertain = false; selected = id; load(); closePatterns()
            report("선택한 화면의 저장값을 불러왔습니다. 적용 버튼으로 시작하세요.")
        } catch { report(error.localizedDescription, error: true) }
    }
    func load() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(Tuning.self, from: data), saved.isValid { tuning = saved }
        else { tuning = Tuning() }
    }
    func save() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(tuning), forKey: key); report("이 모니터의 조정값을 저장했습니다. 다음 실행에서 불러옵니다.") }
        catch { report(error.localizedDescription, error: true) }
    }
    func toggle() {
        guard photoSession == nil else { return }
        do {
            if enabled { try engine.restore(displayID: selected); enabled = false; report("원래 색감으로 보고 있습니다. 조정값은 유지됩니다.") }
            else { try engine.begin(displayID: selected); try engine.apply(tuning, to: selected); enabled = true; report("외장 모니터에 적용 중 · 슬라이더를 움직이면 바로 반영됩니다.") }
            uncertain = false
        } catch { report(error.localizedDescription, error: true) }
    }
    func adjust(_ path: WritableKeyPath<Tuning, Double>, _ value: Double) {
        guard photoSession == nil else { return }
        tuning[keyPath: path] = value
        if enabled {
            do { try engine.apply(tuning, to: selected); report("외장 모니터에 적용 중 · 원래 색감과 번갈아 비교해보세요.") }
            catch { enabled = false; let errors = engine.restoreAll(); report(([error.localizedDescription] + errors).joined(separator: "\n"), error: true) }
        }
    }
    func reset() {
        guard photoSession == nil else { return }
        do { try engine.begin(displayID: selected); try engine.restore(displayID: selected); enabled = false; uncertain = false; tuning = Tuning(); report("원래 색감으로 복원하고 슬라이더를 초기화했습니다. 저장값은 그대로 남아 있습니다.") }
        catch { report(error.localizedDescription, error: true) }
    }
    func adoptBaseline() {
        let alert = NSAlert()
        alert.messageText = "현재 보이는 색감을 새 기준으로 사용할까요?"
        alert.informativeText = "먼저 macOS 디스플레이 설정에서 원하는 색상 프로파일을 선택하세요. 이전 복원 백업은 별도 보존되지만, 이후 초기화는 지금의 색감으로 돌아갑니다."
        alert.addButton(withTitle: "새 기준으로 사용"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try engine.adoptCurrentBaseline(displayID: selected); enabled = false; uncertain = false; tuning = Tuning(); report("현재 macOS 색감이 새 기준입니다. 이전 백업은 보존했습니다.") }
        catch { report(error.localizedDescription, error: true) }
    }
    func closePatterns() { patterns.forEach { $0.close() }; patterns.removeAll() }
    func showPatterns() {
        guard photoSession == nil else { return }
        closePatterns()
        let targets = NSScreen.screens.filter { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return id == selected || CGDisplayIsBuiltin(id) != 0
        }
        for screen in targets {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let title = CGDisplayIsBuiltin(id) != 0 ? "기준 화면 · Mac" : "조정할 화면 · 외장 모니터"
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = title; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PatternView(title: title).frame(minWidth: 540, minHeight: 430))
            w.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 340, y: screen.visibleFrame.midY - 260))
            w.makeKeyAndOrderFront(nil); patterns.append(w)
        }
        report("두 화면의 같은 패치를 비교하세요. ① 흰색 ② 중간 회색 ③ 검정·흰색 계조 순서입니다.")
    }

    func invalidatePhoto() {
        guard photoSession != nil else { return }
        photoTimer?.invalidate(); photoTimer = nil
        tuning = photoOriginal
        photoSession = nil; photoBusy = false; photoPreview = false
        photoMessage = "화면 또는 실행 상태가 바뀌었습니다. 촬영 패턴을 다시 열어 시작하세요."
    }
    func startPhoto(showPatterns: Bool = true) {
        guard photoSession == nil, let display = current else { return }
        let screens = NSScreen.screens
        guard screens.contains(where: { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(id) != 0
        }) else { photoMessage = "기준으로 사용할 Mac 내장 화면을 켜주세요."; return }
        let previous = tuning
        let previousEnabled = enabled
        do {
            try engine.begin(displayID: display.id)
            try engine.restore(displayID: display.id)
            enabled = false
            let baseline = try engine.readback(displayID: display.id)
            photoOriginal = previous; photoWasEnabled = previousEnabled
            photoDisplayID = display.id; photoDisplayIdentity = display.stableID; photoBaseline = baseline
            photoSession = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
            photoBusy = false; photoPreview = false
            enabled = false; uncertain = false
            if showPatterns { try openPhotoPatterns() }
            photoMessage = "두 화면의 QR 표식 8개가 모두 나오게 한 장으로 찍으세요. True Tone은 원하는 상태로 유지하고, 사진을 AirDrop 등으로 Mac에 보낸 뒤 불러오세요. 촬영 후 모니터 설정과 조명을 바꾸지 마세요."
            report("사진 촬영을 위해 앱 보정을 잠시 껐습니다. 취소하면 이전 상태로 돌아갑니다.")
        } catch {
            if photoSession != nil { cancelPhoto() }
            photoMessage = error.localizedDescription
        }
    }
    func openPhotoPatterns() throws {
        guard let session = photoSession else { return }
        closePatterns()
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            guard id == photoDisplayID || CGDisplayIsBuiltin(id) != 0 else { continue }
            let role = CGDisplayIsBuiltin(id) != 0 ? "R" : "E"
            let image = try PhotoPattern.image(session: session, role: role)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = role == "R" ? "사진맞춤 · Mac 기준" : "사진맞춤 · 외장 모니터"
            window.isReleasedWhenClosed = false
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
            view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 360, y: screen.visibleFrame.midY - 260))
            window.makeKeyAndOrderFront(nil); patterns.append(window)
        }
    }
    func showPhotoStatus() {
        closePatterns()
        guard let window = NSApp.windows.first(where: { $0.title == "Mac Color Match" }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showPhotoError(_ detail: String, reuse: (() -> Void)? = nil) {
        photoMessage = detail
        showPhotoStatus()
        let alert = NSAlert()
        alert.alertStyle = reuse == nil ? .warning : .informational
        alert.messageText = reuse == nil ? "사진을 분석하지 못했습니다" : "이전에 찍은 사진을 사용할까요?"
        alert.informativeText = detail
        alert.addButton(withTitle: reuse == nil ? "확인" : "취소")
        if reuse != nil { alert.addButton(withTitle: "촬영 후 설정이 같음 · 이 사진 사용") }
        if let window = NSApp.windows.first(where: { $0.title == "Mac Color Match" }) {
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn { reuse?() }
            }
        }
    }
    func importPhoto() {
        let startedHere = photoSession == nil
        if startedHere { startPhoto(showPatterns: false) }
        guard let session = photoSession, !photoBusy, !photoPreview else {
            if photoSession == nil { showPhotoError("Mac 내장 화면과 외장 모니터가 연결되어 있는지 확인하세요. " + photoMessage) }
            else { showPhotoStatus() }
            return
        }
        let panel = NSOpenPanel()
        panel.title = "두 화면을 함께 찍은 아이폰 사진 선택"
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            if startedHere, photoSession == session { cancelPhoto() }
            return
        }
        guard photoSession == session, !photoBusy, !photoPreview else { return }
        analyzePhoto(url: url, session: session)
    }
    func analyzePhoto(url: URL, session: String, allowPreviousSession: Bool = false) {
        guard photoSession == session, !photoBusy, !photoPreview else { return }
        photoBusy = true
        photoMessage = "두 화면을 찾고 회색 패치의 차이를 분석하고 있습니다…"
        showPhotoStatus()
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PhotoCalibration.analyze(url: url, session: session, allowPreviousSession: allowPreviousSession)
                }.value
                guard self.photoSession == session else { return }
                self.photoBusy = false
                try self.previewPhoto(result)
            } catch {
                guard self.photoSession == session else { return }
                self.photoBusy = false
                if let photoError = error as? PhotoCalibrationError, photoError.canReusePhoto {
                    self.showPhotoError("이전에 띄운 패턴으로 찍은 사진입니다. 촬영 후 모니터의 밝기·색상 설정과 주변 조명이 그대로라면 다시 찍지 않고 사용할 수 있습니다.", reuse: { [weak model = self] in
                        model?.analyzePhoto(url: url, session: session, allowPreviousSession: true)
                    })
                } else {
                    self.showPhotoError(error.localizedDescription + (self.uncertain ? " 아래 화면 복원 오류를 확인하세요." : " 사진을 확인하거나 취소하세요."))
                }
            }
        }
    }
    func previewPhoto(_ result: PhotoFitResult) throws {
        guard current?.id == photoDisplayID, current?.stableID == photoDisplayIdentity,
              let baseline = photoBaseline else { throw DisplayEngineError(message: "대상 모니터가 바뀌었습니다. 새로 촬영하세요.") }
        let currentTable = try engine.readback(displayID: photoDisplayID)
        guard currentTable.maximumDifference(from: baseline) <= GammaEngine.readbackTolerance else {
            throw DisplayEngineError(message: "촬영 중 색상 설정이 바뀌었습니다. 취소한 뒤 새로 촬영하세요.")
        }
        photoStrength = 0.25
        let gentle = result.blendedTuning(strength: photoStrength)
        do {
            try engine.begin(displayID: photoDisplayID)
            try engine.apply(gentle, to: photoDisplayID)
        } catch {
            let recovery = engine.restoreAll()
            enabled = false
            if !recovery.isEmpty { uncertain = true; report(recovery.joined(separator: "\n"), error: true) }
            throw error
        }
        photoFit = result
        tuning = gentle; enabled = true; uncertain = false
        photoPreview = true; photoSeconds = 45
        closePatterns()
        updatePhotoSummary()
        report("사진 추정값을 25% 강도로 미리 적용했습니다. 45초 안에 저장하지 않으면 이전 상태로 돌아갑니다.")
        NSApp.windows.first(where: { $0.title == "Mac Color Match" })?.makeKeyAndOrderFront(nil)
        photoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.photoPreview else { return }
                self.photoSeconds -= 1
                if self.photoSeconds <= 0, self.cancelPhoto() { self.photoMessage = "미리보기 시간이 끝나 이전 설정으로 돌아갔습니다." }
            }
        }
    }
    func updatePhotoSummary() {
        photoMessage = String(format: "보정 강도 %.0f%% · R %.2f / G %.2f / B %.2f / 중간톤 %.2f / 밝기 %.2f\n", photoStrength * 100, tuning.red, tuning.green, tuning.blue, tuning.gamma, tuning.brightness)
            + "사진은 색감을 과하게 추정할 수 있어 약하게 시작합니다. 노랗거나 어색하면 강도를 낮추세요. 0%는 앱 보정 없음, 100%는 사진 추정값 전체입니다."
            + (photoFit?.warnings.isEmpty == false ? "\n" + (photoFit?.warnings.joined(separator: "\n") ?? "") : "")
    }
    func changePhotoStrength(_ amount: Double) {
        guard photoPreview, let fit = photoFit, current?.id == photoDisplayID else { return }
        let next = fit.blendedTuning(strength: amount)
        do {
            try engine.apply(next, to: photoDisplayID)
            photoStrength = min(1, max(0, amount)); tuning = next
            photoSeconds = 45
            updatePhotoSummary()
        } catch {
            let detail = error.localizedDescription
            let restored = cancelPhoto()
            showPhotoError(detail + (restored ? " 이전 설정으로 돌아갔습니다." : " 아래 복원 오류를 확인하세요."))
        }
    }
    func keepPhoto() {
        guard photoPreview else { return }
        save()
        photoTimer?.invalidate(); photoTimer = nil
        photoSession = nil; photoPreview = false; photoBusy = false
        photoMessage = "사진맞춤 프로파일을 저장하고 적용했습니다. 다음 실행에도 이 모니터의 값으로 불러옵니다. 조명이 크게 달라지면 다시 촬영하세요."
        report("사진맞춤 프로파일 적용 중 · 종료하면 원래 색감으로 돌아갑니다.")
    }
    @discardableResult func cancelPhoto() -> Bool {
        guard photoSession != nil else { return true }
        photoTimer?.invalidate(); photoTimer = nil
        photoSession = nil; photoPreview = false; photoBusy = false
        closePatterns()
        tuning = photoOriginal
        do {
            try engine.restore(displayID: photoDisplayID)
            enabled = false
            if photoWasEnabled {
                try engine.begin(displayID: photoDisplayID)
                try engine.apply(photoOriginal, to: photoDisplayID)
                enabled = true
            }
            uncertain = false
            report("사진맞춤을 끝내고 시작 전 설정으로 돌아갔습니다.")
            photoMessage = "이전 조정값을 유지했습니다. ‘촬영 패턴 열기’로 다시 시작할 수 있습니다."
            return true
        } catch {
            enabled = false; report(error.localizedDescription, error: true)
            photoMessage = "이전 화면 상태를 복원하지 못했습니다. 아래 복원 오류를 확인하세요."
            return false
        }
    }
}

struct PatternView: View {
    let title: String
    func gray(_ v: Double) -> Color { Color(.sRGB, red: v, green: v, blue: v, opacity: 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(title).font(.system(size: 17, weight: .semibold)); Spacer(); Text("sRGB 비교 패턴").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 12) {
                ForEach([1.0, 0.75, 0.5], id: \.self) { v in
                    ZStack(alignment: .bottomLeading) { gray(v); Text("\(Int(v * 100))% 회색").font(.caption).foregroundStyle(.black.opacity(0.65)).padding(12) }
                }
            }.frame(maxHeight: .infinity)
            HStack(spacing: 0) { ForEach(0..<21) { n in gray(Double(n)/20) } }.frame(height: 58)
            HStack(spacing: 8) { ForEach([0.0, 0.02, 0.04, 0.06, 0.94, 0.96, 0.98, 1.0], id: \.self) { n in gray(n) } }.frame(height: 42)
            HStack(spacing: 0) {
                Color(.sRGB, red: 0.85, green: 0.18, blue: 0.17, opacity: 1)
                Color(.sRGB, red: 0.20, green: 0.65, blue: 0.35, opacity: 1)
                Color(.sRGB, red: 0.16, green: 0.37, blue: 0.85, opacity: 1)
                Color(.sRGB, red: 0.85, green: 0.68, blue: 0.52, opacity: 1)
                Color(.sRGB, red: 0.55, green: 0.32, blue: 0.23, opacity: 1)
                Color(.sRGB, red: 0.90, green: 0.75, blue: 0.15, opacity: 1)
            }.frame(height: 62)
            Text("흰색의 기운과 회색 밝기를 맞추세요. 맨 아래 색상은 참고용이며, 패널의 색역 차이는 남을 수 있습니다.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(26).background(Color(nsColor: NSColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1))).preferredColorScheme(.dark)
    }
}

struct MatchView: View {
    @ObservedObject var model: MatchModel
    let accent = Color(red: 0.17, green: 0.43, blue: 0.91)
    func slider(_ name: String, _ hint: String, _ path: WritableKeyPath<Tuning, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(name).font(.system(size: 13, weight: .medium)); Spacer(); Text(String(format: "%.2f", model.tuning[keyPath: path])).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
            Slider(value: Binding(get: { model.tuning[keyPath: path] }, set: { model.adjust(path, $0) }), in: range).tint(accent).accessibilityLabel(name)
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 23) {
                HStack(spacing: 10) { Image(systemName: "display.2").font(.title2); Text("Mac Color Match").font(.system(size: 16, weight: .semibold)) }
                Text("두 화면의 색감을\n가깝게 맞추세요.").font(.system(size: 28, weight: .semibold)).lineSpacing(5)
                Text("맥을 기준으로, 외장 모니터의\n흰색과 명암을 직접 조정합니다.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).lineSpacing(5)
                Divider().overlay(.white.opacity(0.14))
                VStack(alignment: .leading, spacing: 18) {
                    step("01", "원하는 맥 색감을 기준으로", "True Tone은 원하는 상태로 두고,\n평소 작업하는 조명을 유지하세요.")
                    step("02", "모니터 메뉴 확인", "표준 또는 sRGB 모드로 설정하고,\n게임·블루라이트·동적 명암을 끄세요.")
                    step("03", "흰색 → 회색 → 계조", "비교 패턴을 열고 색 기운을 줄인 뒤\n중간톤과 밝기를 맞추세요.")
                }
                Button("macOS 디스플레이 설정 열기") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 8)
                Text("소프트웨어 미세 조정 도구\n정밀 색 교정에는 측색기와 ICC 프로파일이 필요합니다.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.48)).lineSpacing(4)
            }.padding(28).frame(width: 300).frame(maxHeight: .infinity).background(Color(red: 0.09, green: 0.13, blue: 0.20)).foregroundStyle(.white)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("외장 모니터 조정").font(.system(size: 23, weight: .semibold)); Spacer(); Text(model.uncertain ? "복원 확인 필요" : (model.enabled ? "적용 중" : "원래 색감")).font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 6).background((model.uncertain ? Color.orange : (model.enabled ? Color.green : Color.gray)).opacity(0.12)).clipShape(Capsule()) }
                    Picker("대상 화면", selection: Binding(get: { model.selected }, set: { model.select($0) })) {
                        if model.external.isEmpty { Text("외장 모니터를 연결하세요").tag(UInt32(0)) }
                        ForEach(model.external) { d in Text("\(d.name) · \(d.width)×\(d.height)").tag(d.id) }
                    }.disabled(model.external.isEmpty || model.photoSession != nil)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("아이폰 사진으로 자동 맞춤", systemImage: "camera.viewfinder").font(.system(size: 15, weight: .semibold))
                        Text(model.photoMessage).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.photoBusy { ProgressView("사진 분석 중…").controlSize(.small) }
                        if model.photoPreview {
                            HStack {
                                Text("보정 강도").font(.system(size: 12, weight: .medium))
                                Slider(value: Binding(get: { model.photoStrength }, set: { model.changePhotoStrength($0) }), in: 0...1).accessibilityLabel("사진 보정 강도")
                                Text("\(Int((model.photoStrength * 100).rounded()))%").font(.system(size: 12, design: .monospaced)).frame(width: 40)
                            }
                            Text("\(model.photoSeconds)초 후 이전 설정으로 복원").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                            HStack {
                                Button("이 설정 저장하고 유지") { model.keepPhoto() }.buttonStyle(.borderedProminent)
                                Button("이전 설정으로") { model.cancelPhoto() }
                            }
                        } else if model.photoSession != nil {
                            HStack {
                                Button("사진 불러오기") { model.importPhoto() }.disabled(model.photoBusy)
                                Button("촬영 패턴 다시 보기") { do { try model.openPhotoPatterns() } catch { model.photoMessage = error.localizedDescription } }.disabled(model.photoBusy)
                                Button("취소") { model.cancelPhoto() }
                            }
                        } else {
                            HStack {
                                Button("촬영 패턴 열기") { model.startPhoto() }.disabled(model.current == nil)
                                Button("기존 사진 불러오기") { model.importPhoto() }.disabled(model.current == nil)
                            }
                        }
                    }.padding(16).background(accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Button("두 화면에 비교 패턴 열기") { model.showPatterns() }.disabled(model.current == nil)
                        Button("패턴 닫기") { model.closePatterns() }
                    }.disabled(model.photoSession != nil)
                    VStack(alignment: .leading, spacing: 7) {
                        Label("흰색 균형", systemImage: "circle.lefthalf.filled").font(.system(size: 14, weight: .semibold))
                        Text("푸르면 파랑을, 붉으면 빨강을 줄이세요. 노랗다면 빨강과 초록을 조금씩 줄이세요.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        slider("빨강", "붉은 기운 줄이기", \.red, 0.7...1)
                        slider("초록", "초록 기운 줄이기", \.green, 0.7...1)
                        slider("파랑", "푸른 기운 줄이기", \.blue, 0.7...1)
                        Divider().padding(.vertical, 5)
                        slider("중간톤", "왼쪽은 어둡게 · 오른쪽은 밝게", \.gamma, 0.7...1.4)
                        slider("밝기", "소프트웨어 감광 · 먼저 모니터 자체 밝기를 맞추세요", \.brightness, 0.65...1)
                    }.padding(18).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12)).disabled(model.current == nil || model.photoSession != nil)
                    Text(model.message).font(.system(size: 12)).foregroundStyle(model.failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true).frame(minHeight: 35, alignment: .topLeading).accessibilityIdentifier("status")
                    if model.uncertain { Button("현재 macOS 색감을 새 기준으로 사용…") { model.adoptBaseline() }.disabled(model.current == nil || model.photoSession != nil) }
                    HStack(spacing: 10) {
                        Button(model.enabled ? "원래 색감 보기" : "조정값 적용") { model.toggle() }.buttonStyle(.borderedProminent).tint(accent)
                        Button("조정값 저장") { model.save() }
                        Spacer()
                        Button("초기화") { model.reset() }
                    }.disabled(model.current == nil || model.photoSession != nil)
                    Text("앱을 실행하는 동안 적용됩니다. 종료·잠자기 시 원래 색감으로 복원하며, 저장값은 다음 실행에서 직접 적용할 수 있습니다.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(28)
            }.background(Color(red: 0.95, green: 0.96, blue: 0.98))
        }.frame(minWidth: 900, minHeight: 780).preferredColorScheme(.light)
    }
    func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineSpacing(4) }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: MatchModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "local.yoogeon.MacColorMatch").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        model = MatchModel()
        let menu = NSMenu()
        let appMenu = NSMenu(); let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
        appMenu.addItem(withTitle: "Mac Color Match 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let photoMenu = NSMenu(title: "사진맞춤")
        let photoMenuItem = NSMenuItem(title: "사진맞춤", action: nil, keyEquivalent: "")
        photoMenuItem.submenu = photoMenu; menu.addItem(photoMenuItem)
        for (title, action, key) in [("촬영 패턴 열기", #selector(startPhotoMenu), "p"), ("사진 불러오기…", #selector(importPhotoMenu), "o"), ("사진맞춤 취소", #selector(cancelPhotoMenu), "")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; photoMenu.addItem(item)
        }
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mac Color Match"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MatchView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc func startPhotoMenu() { model.startPhoto() }
    @objc func importPhotoMenu() { model.importPhoto() }
    @objc func cancelPhotoMenu() { model.cancelPhoto() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil else { return .terminateNow }
        let errors = model.engine.restoreAll()
        if !errors.isEmpty {
            let alert = NSAlert(); alert.messageText = "일부 화면을 자동 복원하지 못했습니다"
            alert.informativeText = errors.joined(separator: "\n") + "\n계속 종료하면 다음 실행에서 복구를 시도할 수 있습니다."
            alert.addButton(withTitle: "돌아가기"); alert.addButton(withTitle: "종료")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model.closePatterns(); return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
