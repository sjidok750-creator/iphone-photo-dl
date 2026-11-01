// 터미널 모드: 엔진의 알림을 줄로 찍고, 진행 줄을 덮어 쓰고, 끝나면 종료 코드로 끝낸다.

import Foundation

enum ExitCode {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let disconnected: Int32 = 2
    static let noDevice: Int32 = 3
    static let noSpace: Int32 = 4
    static let someFailed: Int32 = 5
    static let interrupted: Int32 = 130
}

final class CLIRunner {
    private let opts: Options
    private let console: Console
    private let engine: Engine
    private let startedAt = Date()
    private var lastPlain = Date.distantPast
    private var exiting = false
    private var promptedBatch = 0

    init(options: Options, console: Console) {
        opts = options
        self.console = console
        var cfg = EngineConfig(destination: options.destination)
        cfg.layout = options.layout
        cfg.kinds = options.kinds
        cfg.since = options.since
        cfg.limit = options.limit
        cfg.window = options.window
        cfg.requestOriginals = options.requestOriginals
        cfg.planOnly = options.listOnly || options.dryRun
        cfg.newestFirst = options.newestFirst
        cfg.batchSize = options.batchSize
        engine = Engine(config: cfg)
        engine.onMessage = { [weak self] text in self?.console.line(text) }
        engine.onChange = { [weak self] in self?.update() }
    }

    func start() {
        console.line("아이폰을 찾는 중… (USB 케이블로 연결하고 아이폰 잠금을 풀어 두세요)")
        engine.start()
    }

    func interrupt() {
        guard !exiting else { return }
        console.line()
        console.line("중단했습니다. 다시 실행하면 받은 것은 건너뛰고 이어서 받습니다.")
        quit(ExitCode.interrupted)
    }

    private func update() {
        guard !exiting else { return }
        switch engine.stage {
        case .searching:
            if engine.disconnects > 0 {
                quit(ExitCode.disconnected)
            } else if !engine.everConnected && Date().timeIntervalSince(startedAt) > opts.timeout {
                console.line("""
                아이폰을 찾지 못했습니다 (\(Int(opts.timeout))초).
                  · 케이블을 Mac 에 바로 꽂았는지(허브 말고) 확인하세요.
                  · 아이폰 잠금을 풀고, '이 컴퓨터를 신뢰하겠습니까?'에서 '신뢰'를 누르세요.
                  · Mac 에 USB 액세서리 연결을 묻는 창이 떴다면 '허용'. 전에 '허용 안 함'을 눌렀다면
                    시스템 설정 > 개인정보 보호 및 보안 > 액세서리 에서 바꾸세요.
                  · Mac 의 '이미지 캡처' 앱에서 아이폰이 보이는지 확인하세요. 거기서도 안 보이면 macOS 쪽 연결 문제입니다.
                """)
                quit(ExitCode.noDevice)
            }
        case .cataloging:
            let lock = engine.isLocked ? " · 아이폰 잠금을 풀어 주세요" : ""
            show("목록 읽는 중 \(engine.catalogPercent)% · \(formatCount(engine.catalogCount))개\(lock)")
        case .planned:
            if opts.dryRun {
                console.line()
                for it in engine.plan.items {
                    console.line("  \(it.relPath)  (\(formatBytes(it.media.size)))")
                }
                console.line("(--dry-run: 실제로 받지는 않았습니다)")
            }
            quit(ExitCode.ok)
        case .downloading, .paused:
            let total = engine.jobTotalBytes
            let cur = engine.currentBytes
            let pct = total > 0 ? Double(cur) / Double(total) * 100 : 100
            let lock = engine.isLocked ? " · 아이폰 잠금을 풀어 주세요" : ""
            show("받는 중 \(formatCount(engine.doneCount))/\(formatCount(engine.jobTotalCount)) (\(String(format: "%.1f", pct))%) · "
                 + "\(formatBytes(cur))/\(formatBytes(total)) · \(formatBytes(Int64(engine.speed)))/s · 남은 시간 \(formatDuration(engine.remainingSeconds))\(lock)")
        case .confirmDelete:
            guard let s = engine.batchSummary, promptedBatch != s.number else { break }
            promptedBatch = s.number
            console.clearStatus()
            console.line()
            console.line("── 묶음 \(s.number)/\(s.count) ── 맥에 저장된 것을 확인한 사진 \(formatCount(s.photos))장 (파일 \(formatCount(s.files))개, \(formatBytes(s.bytes)))")
            if let a = s.oldest, let b = s.newest { console.line("   찍은 날짜: \(dayText(a)) ~ \(dayText(b))") }
            if s.unverifiedPhotos > 0 { console.line("   원본 그대로 저장된 것이 확인되지 않은 \(s.unverifiedPhotos)장은 지우지 않습니다.") }
            if s.convertedPhotos > 0 { console.line("   그중 \(s.convertedPhotos)장은 변환본만 있습니다 → 아이폰 설정 > 사진 > 'Mac 또는 PC로 전송'을 '원본 유지'로.") }
            if s.firstTrial { console.line("   처음이라 \(s.photos)장만 먼저 지웁니다. 지운 뒤 아이폰 '최근 삭제된 항목'과 맥의 사진을 확인해 보세요.") }
            if engine.iCloudOn { console.line("   주의: iCloud 사진이 켜져 있어, 지우면 iCloud 와 다른 기기에서도 지워질 수 있습니다.") }
            if let h = engine.deleteBlockedHint { console.line("   참고: \(h)") }
            console.line("아이폰에서 이 사진들을 지울까요?  y = 지우기 · Enter = 지우지 않고 다음 · q = 그만")
            FileHandle.standardOutput.write("> ".data(using: .utf8)!)
            let answer = (readLine() ?? "q").trimmingCharacters(in: .whitespaces).lowercased()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch answer {
                case "y", "yes", "예", "ㅛ":
                    self.engine.deleteCurrentBatch()
                case "q", "quit", "그만", "ㅂ":
                    self.engine.stopBatches()
                default:
                    self.engine.keepCurrentBatch()
                }
            }
        case .deleting:
            show("아이폰에서 지우는 중…")
        case .finished:
            console.line("저장 위치: \(engine.destination)")
            console.line("기록: \(Log.shared.url.path)")
            if opts.openWhenDone { openFolder(engine.destination) }
            quit(engine.failedCount > 0 ? ExitCode.someFailed : ExitCode.ok)
        case .failed:
            console.line("기록: \(Log.shared.url.path)")
            quit(engine.failureKind == .storage ? ExitCode.noSpace : ExitCode.error)
        case .connecting:
            break
        }
    }

    private func show(_ text: String) {
        if console.isTTY {
            console.status(text)
        } else if Date().timeIntervalSince(lastPlain) >= 10 {
            console.line(text)
            lastPlain = Date()
        }
    }

    private func quit(_ code: Int32) {
        exiting = true
        console.clearStatus()
        engine.shutdown()
        // 세션 닫기 요청이 나갈 짬을 준 뒤 끝낸다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(code) }
    }
}

/// 2024-05-03 (금)
func dayText(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = "yyyy-MM-dd (E)"
    return f.string(from: d)
}

func openFolder(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [path]
    try? p.run()
    p.waitUntilExit()
}
