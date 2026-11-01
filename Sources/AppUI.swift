// 창(앱) 화면: 열고 아이폰을 꽂으면 저절로 받는다.
// 큰 제목 한 줄(지금 상태·할 일) + 설명 + 진행 막대 + 저장 위치 + 단추 몇 개.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        main = MainWindow()
        main?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = main else { return .terminateNow }
        return m.confirmQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        main?.engine.shutdown()
    }

    private func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "\(appDisplayName) 정보 (\(appVersion))", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "\(appDisplayName) 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = bar
    }
}

/// 화면에 그릴 값 (엔진에서 읽거나, 시험용 미리보기)
struct ScreenState {
    var stage = Stage.searching
    var isLocked = false
    var isBusy = false
    var deviceName = ""
    var destination = defaultDestination
    var catalogPercent = 0
    var catalogCount = 0
    var doneCount = 0
    var doneBytes: Int64 = 0
    var jobTotalCount = 0
    var jobTotalBytes: Int64 = 0
    var currentBytes: Int64 = 0
    var speed = 0.0
    var remainingSeconds = Double.nan
    var elapsed = 0.0
    var failedCount = 0
    var totalOnPhone = 0
    var notices = Set<Notice>()
    var closedAppNames: [String] = []
    var lastResult: String?

    init() {}

    init(_ e: Engine) {
        stage = e.stage
        isLocked = e.isLocked
        isBusy = e.isBusy
        deviceName = e.deviceName
        destination = e.destination
        catalogPercent = e.catalogPercent
        catalogCount = e.catalogCount
        doneCount = e.doneCount
        doneBytes = e.doneBytes
        jobTotalCount = e.jobTotalCount
        jobTotalBytes = e.jobTotalBytes
        currentBytes = e.currentBytes
        speed = e.speed
        remainingSeconds = e.remainingSeconds
        elapsed = e.elapsed
        failedCount = e.failedCount
        totalOnPhone = e.plan.totalCount
        notices = e.notices
        closedAppNames = e.closedAppNames
        lastResult = e.lastResult
    }

    static func preview(_ name: String?) -> ScreenState? {
        guard let name = name, !name.isEmpty else { return nil }
        var s = ScreenState()
        s.deviceName = "iPhone"
        s.jobTotalCount = 2_345
        s.jobTotalBytes = 15_300_000_000
        switch name {
        case "downloading":
            s.stage = .downloading
            s.isBusy = true
            s.doneCount = 1_234
            s.currentBytes = 8_000_000_000
            s.speed = 28_100_000
            s.remainingSeconds = 260
            s.notices = [.converting, .closedApps]
            s.closedAppNames = ["사진"]
        case "locked":
            s.stage = .downloading
            s.isBusy = true
            s.isLocked = true
            s.doneCount = 300
            s.currentBytes = 2_000_000_000
        case "partial":
            s.stage = .finished
            s.doneCount = 2_340
            s.doneBytes = 15_200_000_000
            s.failedCount = 5
            s.elapsed = 560
            s.notices = [.stalled, .iCloudOn]
        case "failed":
            s.stage = .failed("아이폰과의 전송이 멈췄습니다.\n케이블을 뺐다 다시 꽂아 주세요. 받은 것은 건너뛰고 이어서 받습니다.")
        default:
            s.stage = .searching
        }
        return s
    }
}

final class MainWindow: NSObject, NSWindowDelegate {
    let engine: Engine
    private let window: NSWindow

    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let stats = NSTextField(labelWithString: "")
    private let folderField = NSTextField(labelWithString: "")
    private let updateLabel = NSTextField(labelWithString: "")
    private var changeButton: NSButton!
    private var actionButton: NSButton!
    private var openButton: NSButton!
    private var logButton: NSButton!
    private var updateButton: NSButton!
    private var updateRow: NSStackView!

    private var quitConfirmed = false
    private var announcedFinish = false
    private var newerVersion: String?
    /// 화면 모양 시험용(빌드 서버): IPDL_UI_PREVIEW=downloading|locked|partial|failed
    private let previewState = ScreenState.preview(ProcessInfo.processInfo.environment["IPDL_UI_PREVIEW"])

    private static let folderKey = "destination"

    override init() {
        engine = Engine(config: EngineConfig(destination: MainWindow.initialDestination()))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = appDisplayName
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildLayout()
        if previewState == nil {
            engine.onChange = { [weak self] in self?.render() }
            engine.start()
            checkForUpdate()
        }
        render()
    }

    /// 전에 고른 폴더(앱 설정 → 0.9 의 터미널 실행기가 남긴 기록) → 기본 폴더
    private static func initialDestination() -> String {
        let fm = FileManager.default
        if let saved = UserDefaults.standard.string(forKey: folderKey), !saved.isEmpty {
            return saved
        }
        let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent(".iphone-photo-dl/last_folder")
        if let text = try? String(contentsOf: legacy, encoding: .utf8) {
            var p = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }
            if !p.isEmpty && fm.fileExists(atPath: p) { return p }
        }
        return defaultDestination
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 화면 짜기

    private func buildLayout() {
        headline.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        headline.lineBreakMode = .byTruncatingTail
        detail.font = NSFont.systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 5
        detail.preferredMaxLayoutWidth = 532
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        stats.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        stats.textColor = .secondaryLabelColor
        folderField.font = NSFont.systemFont(ofSize: 12)
        folderField.lineBreakMode = .byTruncatingMiddle
        folderField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let folderTitle = NSTextField(labelWithString: "저장 위치")
        folderTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        changeButton = NSButton(title: "바꾸기…", target: self, action: #selector(changeFolder))
        openButton = NSButton(title: "폴더 열기", target: self, action: #selector(openDestination))
        logButton = NSButton(title: "기록 보기", target: self, action: #selector(openLog))
        actionButton = NSButton(title: "멈춤", target: self, action: #selector(primaryAction))
        actionButton.keyEquivalent = "\r"
        updateButton = NSButton(title: "업데이트", target: self, action: #selector(runUpdate))
        for b in [changeButton!, openButton!, logButton!, actionButton!, updateButton!] {
            b.bezelStyle = .rounded
        }

        updateLabel.font = NSFont.systemFont(ofSize: 12)
        updateLabel.textColor = .systemBlue
        updateRow = NSStackView(views: [updateLabel, updateButton])
        updateRow.orientation = .horizontal
        updateRow.spacing = 8
        updateRow.isHidden = true

        let folderRow = NSStackView(views: [folderTitle, folderField, changeButton])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [logButton, spacer, openButton, actionButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let sep = NSBox()
        sep.boxType = .separator

        // 위: 상태·설명·진행 / 아래: 저장 위치·단추 (창 아래에 붙임)
        let top = NSStackView(views: [headline, detail, bar, stats, updateRow])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 12
        top.setCustomSpacing(8, after: headline)
        top.translatesAutoresizingMaskIntoConstraints = false

        let bottom = NSStackView(views: [sep, folderRow, buttonRow])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 12
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(top)
        content.addSubview(bottom)
        var constraints = [
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            bottom.topAnchor.constraint(greaterThanOrEqualTo: top.bottomAnchor, constant: 20),
            content.widthAnchor.constraint(equalToConstant: 580),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ]
        for v in [headline, detail, bar] as [NSView] {
            constraints.append(v.widthAnchor.constraint(equalTo: top.widthAnchor))
        }
        for v in [sep, folderRow, buttonRow] as [NSView] {
            constraints.append(v.widthAnchor.constraint(equalTo: bottom.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        window.contentView = content
    }

    // MARK: - 그리기

    private func render() {
        let e = previewState ?? ScreenState(engine)
        folderField.stringValue = (e.destination as NSString).abbreviatingWithTildeInPath
        window.title = e.deviceName.isEmpty ? appDisplayName : "\(appDisplayName) — \(e.deviceName)"
        headline.textColor = .labelColor

        var h = ""
        var d = ""
        var showBar = false
        var pct = 0.0
        var st = ""
        var action: String?

        switch e.stage {
        case .searching:
            h = "아이폰을 USB 케이블로 연결하세요"
            d = "연결한 뒤 아이폰 잠금을 풀어 주세요. 처음 연결하면 아이폰에 '이 컴퓨터를 신뢰하겠습니까?'가 뜹니다 — '신뢰'를 누르세요.\n연결되면 저절로 받기 시작합니다."
            if let last = e.lastResult { d = last + "\n\n" + d }
        case .connecting:
            h = "아이폰에 연결하는 중…"
            d = "잠시 기다려 주세요."
        case .cataloging:
            h = "사진 목록을 읽는 중… \(e.catalogPercent)%"
            d = "\(formatCount(e.catalogCount))개 확인했습니다. 사진이 많으면 몇 분 걸립니다.\n아이폰 잠금을 풀어 두세요."
            showBar = true
            pct = Double(e.catalogPercent)
        case .planned:
            h = "목록 확인 끝"
        case .downloading, .paused:
            let paused = e.stage == .paused
            h = paused ? "멈춤 — \(formatCount(e.doneCount)) / \(formatCount(e.jobTotalCount))개"
                       : "받는 중  \(formatCount(e.doneCount)) / \(formatCount(e.jobTotalCount))개"
            d = tips(e).joined(separator: "\n")
            if d.isEmpty {
                d = "받는 동안 아이폰 화면이 꺼지지 않게 해 두면 좋습니다 (설정 > 디스플레이 및 밝기 > 자동 잠금 > 안 함).\n노트북은 전원을 연결해 두세요."
            }
            showBar = true
            pct = e.jobTotalBytes > 0 ? Double(e.currentBytes) / Double(e.jobTotalBytes) * 100 : 0
            st = "\(formatBytes(e.currentBytes)) / \(formatBytes(e.jobTotalBytes))"
            if !paused {
                st += " · \(formatBytes(Int64(e.speed)))/s · 남은 시간 \(formatDuration(e.remainingSeconds))"
            }
            action = paused ? "계속" : "멈춤"
        case .finished:
            if e.jobTotalCount == 0 {
                h = "새 사진이 없습니다"
                d = "아이폰의 사진·동영상 \(formatCount(e.totalOnPhone))개를 이미 모두 받았습니다."
            } else if e.failedCount == 0 {
                h = "완료! \(formatCount(e.doneCount))개를 받았습니다"
                d = "\(formatBytes(e.doneBytes)) · 걸린 시간 \(formatDuration(e.elapsed)). 다음부터는 새로 찍은 것만 받습니다."
                showBar = true
                pct = 100
            } else {
                h = "\(formatCount(e.doneCount))개 받음 · \(formatCount(e.failedCount))개는 받지 못했습니다"
                headline.textColor = .systemOrange
                d = "'다시 받기'를 누르면 받지 못한 것만 다시 받습니다. 계속 안 되면 아이폰 설정 > 사진 > 'Mac 또는 PC로 전송'을 '원본 유지'로 바꿔 보세요."
                action = "다시 받기"
            }
            let t = tips(e).filter { !$0.contains("다시 시도했습니다") }
            if !t.isEmpty { d += "\n" + t.joined(separator: "\n") }
        case .failed(let text):
            h = "잠깐 멈췄습니다"
            headline.textColor = .systemOrange
            d = text
            action = "다시 시도"
        }

        if e.isLocked && (e.stage == .connecting || e.stage == .cataloging || e.stage == .downloading) {
            h = "아이폰 잠금을 풀어 주세요"
            headline.textColor = .systemOrange
            d = "잠금을 풀면 저절로 이어서 진행합니다. 처음 연결이면 아이폰에서 '이 컴퓨터를 신뢰'를 누르세요."
            if e.stage == .downloading {
                st = "\(formatBytes(e.currentBytes)) / \(formatBytes(e.jobTotalBytes))"
            }
        }

        headline.stringValue = h
        detail.stringValue = d
        detail.isHidden = d.isEmpty
        bar.isHidden = !showBar
        bar.doubleValue = pct
        stats.isHidden = st.isEmpty
        stats.stringValue = st
        actionButton.isHidden = action == nil
        if let a = action { actionButton.title = a }
        changeButton.isEnabled = !e.isBusy
        updateRow.isHidden = newerVersion == nil || e.isBusy

        if e.stage == .finished && e.jobTotalCount > 0 {
            if !announcedFinish {
                announcedFinish = true
                NSSound(named: "Glass")?.play()
                NSApp.requestUserAttention(.informationalRequest)
            }
        } else if e.stage != .finished {
            announcedFinish = false
        }
    }

    private func tips(_ e: ScreenState) -> [String] {
        var t: [String] = []
        if e.notices.contains(.converting) || e.notices.contains(.manyErrors) {
            t.append("느리거나 실패하면: 아이폰 설정 > 사진 > 'Mac 또는 PC로 전송'을 '원본 유지'로 바꾸세요.")
        }
        if e.notices.contains(.stalled) {
            t.append("전송이 잠시 멈춰서 저절로 다시 시도했습니다.")
        }
        if e.notices.contains(.closedApps) {
            t.append("\(e.closedAppNames.joined(separator: "·")) 앱이 아이폰을 함께 붙잡지 않도록 닫았습니다.")
        }
        if e.notices.contains(.iCloudOn) {
            t.append("iCloud 사진 사용 중 — 'iPhone 저장 공간 최적화'면 아이폰에 원본이 없는 사진은 받을 수 없습니다.")
        }
        return t
    }

    // MARK: - 단추

    @objc private func primaryAction() {
        switch engine.stage {
        case .downloading: engine.pause()
        case .paused: engine.resume()
        case .finished, .failed: engine.retry()
        default: break
        }
    }

    @objc private func changeFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "선택"
        p.message = "아이폰 사진을 받을 폴더를 고르세요 (그 안에 연/월 폴더로 정리됩니다)"
        let cur = URL(fileURLWithPath: engine.destination, isDirectory: true)
        p.directoryURL = FileManager.default.fileExists(atPath: cur.path) ? cur : cur.deletingLastPathComponent()
        p.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = p.url, let self = self else { return }
            UserDefaults.standard.set(url.path, forKey: MainWindow.folderKey)
            self.engine.setDestination(url.path)
            self.render()
        }
    }

    @objc private func openDestination() {
        openFolder(engine.destination)
    }

    @objc private func openLog() {
        Log.shared.flush()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-e", Log.shared.url.path]
        try? p.run()
    }

    // MARK: - 새 버전

    private func checkForUpdate() {
        guard let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  isNewerVersion(tag, than: appVersion) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.newerVersion = tag
                self.updateLabel.stringValue = "새 버전 \(tag) 이(가) 있습니다."
                Log.shared.write("새 버전 있음: \(tag)")
                self.render()
            }
        }.resume()
    }

    @objc private func runUpdate() {
        guard !engine.isBusy else { return }
        Log.shared.write("업데이트 시작 → \(newerVersion ?? "?")")
        // 이 앱이 끝난 뒤 설치 스크립트가 새 앱으로 바꾸고 다시 연다.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 2; \(installCommand) >> \"$HOME/Library/Logs/iphone-photo-dl-update.log\" 2>&1"]
        do {
            try p.run()
            quitConfirmed = true
            NSApp.terminate(nil)
        } catch {
            let a = NSAlert()
            a.messageText = "업데이트를 시작하지 못했습니다"
            a.informativeText = "터미널에 아래 한 줄을 붙여 넣어 주세요.\n\(installCommand)"
            a.runModal()
        }
    }

    // MARK: - 닫기

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return confirmQuit()
    }

    func confirmQuit() -> Bool {
        if quitConfirmed || !engine.isBusy { return true }
        let a = NSAlert()
        a.messageText = "사진을 받는 중입니다. 끝낼까요?"
        a.informativeText = "다시 열면 받은 것은 건너뛰고 이어서 받습니다."
        a.addButton(withTitle: "계속 받기")
        a.addButton(withTitle: "끝내기")
        if a.runModal() == .alertSecondButtonReturn {
            quitConfirmed = true
            return true
        }
        return false
    }
}
