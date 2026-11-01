// 아이폰 연결과 내려받기. macOS 기본 프레임워크 ImageCaptureCore('이미지 캡처' 앱과 같은 통로)만 쓴다.
// 순서: 기기 찾기 → 세션 열기 → 전체 목록(카탈로그) 받기 → 계획 → 여러 개를 줄 세워 내려받기.
// 내려받는 파일은 저장폴더/.iphone-photo-dl/tmp 에 먼저 받고, 끝나면 제자리로 옮긴 뒤 받은 목록에 적는다.
// 그래서 중간에 끊겨도 다시 실행하면 받은 것은 건너뛰고 이어서 받는다.

import Foundation
import CoreGraphics
import ImageCaptureCore

enum ExitCode {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let disconnected: Int32 = 2
    static let noDevice: Int32 = 3
    static let noSpace: Int32 = 4
    static let someFailed: Int32 = 5
    static let interrupted: Int32 = 130
}

final class Importer: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    private enum Phase { case searching, opening, cataloging, downloading, finished }

    private let opts: Options
    private let console: Console
    private let fm = FileManager.default
    private let destRoot: URL
    private let stateDir: URL
    private let tmpDir: URL

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var phase = Phase.searching

    private var cameraFiles: [ICCameraFile] = []
    private var plan = Plan()
    private var manifest: Manifest?

    private var pending: [Int] = []                  // plan.items 번호
    private var pendingPos = 0
    private var inFlight: [Int: ObjectIdentifier] = [:]
    private var partialBytes: [ObjectIdentifier: Int64] = [:]
    private var tmpNames: [Int: String] = [:]
    private var attempts: [Int: Int] = [:]
    private var failed: [Int: String] = [:]
    private var doneCount = 0
    private var doneBytes: Int64 = 0
    private var restricted = false

    private var startedAt = Date()
    private var catalogStartedAt = Date()
    private var catalogItemCount = 0
    private var samples: [(t: Date, bytes: Int64)] = []
    private var lastPlainReport = Date.distantPast
    private var searchTimer: Timer?
    private var tickTimer: Timer?
    private var restrictedNoticeShown = false
    private var activity: NSObjectProtocol?

    init(options: Options, console: Console) {
        opts = options
        self.console = console
        destRoot = URL(fileURLWithPath: options.destination, isDirectory: true)
        stateDir = destRoot.appendingPathComponent(stateDirName, isDirectory: true)
        tmpDir = stateDir.appendingPathComponent("tmp", isDirectory: true)
        super.init()
    }

    // MARK: - 시작

    func start() {
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
        console.line("아이폰을 찾는 중… (USB 케이블로 연결하고 아이폰 잠금을 풀어 두세요)")
        searchTimer = Timer.scheduledTimer(withTimeInterval: opts.timeout, repeats: false) { [weak self] _ in
            self?.searchTimedOut()
        }
    }

    private func searchTimedOut() {
        guard phase == .searching else { return }
        console.line("""
        아이폰을 찾지 못했습니다 (\(Int(opts.timeout))초).
          · 케이블을 Mac 에 바로 꽂았는지(허브 말고) 확인하세요.
          · 아이폰 잠금을 풀고, '이 컴퓨터를 신뢰하겠습니까?'에서 '신뢰'를 누르세요.
          · Mac 의 '이미지 캡처' 앱에서 아이폰이 보이는지 확인하세요. 거기서도 안 보이면 macOS 쪽 연결 문제입니다.
        """)
        finish(code: ExitCode.noDevice)
    }

    func interrupt() {
        guard phase != .finished else { return }
        console.line()
        console.line("중단했습니다. 다시 실행하면 받은 것은 건너뛰고 이어서 받습니다.")
        if phase == .downloading { printSummary() }
        finish(code: ExitCode.interrupted)
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, phase == .searching, let cam = device as? ICCameraDevice else { return }
        camera = cam
        searchTimer?.invalidate()
        phase = .opening
        console.line("연결됨: \(cam.name ?? "이름 없는 기기")")
        cam.delegate = self
        // 기기가 HEIC 를 JPEG 로 바꿔 보내지 않고 원본을 주도록 요청한다(지원하는 macOS 에서).
        cam.mediaPresentation = .originalAssets
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if let cam = camera, device === cam { deviceGone() }
    }

    // MARK: - ICDeviceDelegate

    func didRemove(_ device: ICDevice) {
        if let cam = camera, device === cam { deviceGone() }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let e = error {
            console.line("아이폰 연결을 열지 못했습니다: \(e.localizedDescription)")
            console.line("사진 앱이나 이미지 캡처 앱이 열려 있으면 닫고 다시 실행하세요.")
            finish(code: ExitCode.error)
            return
        }
        guard phase == .opening else { return }
        phase = .cataloging
        catalogStartedAt = Date()
        console.line("사진 목록을 읽는 중… (사진이 많으면 몇 분 걸립니다)")
        if let cam = camera, cam.isAccessRestrictedAppleDevice { showRestrictedNotice() }
        startTicker()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        if let e = error, phase != .finished {
            console.line("기기 오류: \(e.localizedDescription)")
        }
    }

    // MARK: - ICCameraDeviceDelegate

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        if phase == .cataloging || phase == .opening { catalogItemCount += items.count }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        restricted = true
        showRestrictedNotice()
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        let wasRestricted = restricted || restrictedNoticeShown
        restricted = false
        restrictedNoticeShown = false
        if wasRestricted { console.line("아이폰 잠금이 풀렸습니다. 계속합니다.") }
        if phase == .downloading { pump() }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard phase == .cataloging || phase == .opening else { return }
        console.clearStatus()
        let files = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        cameraFiles = files
        var media: [MediaInfo] = []
        media.reserveCapacity(files.count)
        for (i, f) in files.enumerated() {
            media.append(MediaInfo(id: i,
                                   name: f.name ?? "unnamed",
                                   folder: f.parentFolder?.name ?? "",
                                   size: Int64(f.fileSize),
                                   date: f.creationDate ?? f.modificationDate))
        }
        let took = Date().timeIntervalSince(catalogStartedAt)
        console.line("목록 읽기 끝: \(formatCount(files.count))개 (\(formatDuration(took)))")
        if device.iCloudPhotosEnabled {
            console.line("""
            참고: 이 아이폰은 iCloud 사진을 씁니다. 설정 > 사진 에서 'iPhone 저장 공간 최적화'가 켜져 있으면
                  원본이 아이폰에 없는 사진은 목록에 없거나 받을 수 없습니다('다운로드 및 원본 유지'로 바꾸면 모두 받을 수 있음).
            """)
        }
        planAndRun(media)
    }

    // MARK: - 계획

    private func planAndRun(_ media: [MediaInfo]) {
        let man = Manifest(stateDirectory: stateDir)
        manifest = man
        let root = destRoot
        let fm = self.fm
        plan = makePlan(media: media, options: opts, manifest: man.entries) { rel in
            let path = root.appendingPathComponent(rel).path
            guard let a = try? fm.attributesOfItem(atPath: path),
                  (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
            return (a[.size] as? NSNumber)?.int64Value
        }

        console.line()
        console.line("아이폰 전체: \(formatCount(plan.totalCount))개 (사진 \(formatCount(plan.photoCount)) · 동영상 \(formatCount(plan.videoCount))), \(formatBytes(plan.totalBytes))")
        if plan.alreadyInManifest + plan.adopted.count > 0 {
            console.line("이미 받은 것: \(formatCount(plan.alreadyInManifest + plan.adopted.count))개 → 건너뜀")
        }
        if plan.filteredOut > 0 {
            console.line("조건으로 뺀 것: \(formatCount(plan.filteredOut))개")
        }
        console.line("받을 것: \(formatCount(plan.items.count))개, \(formatBytes(plan.bytesToDownload))")
        console.line("저장 위치: \(destRoot.path)")

        if opts.listOnly {
            finish(code: ExitCode.ok)
            return
        }
        if opts.dryRun {
            console.line()
            for it in plan.items {
                console.line("  \(it.relPath)  (\(formatBytes(it.media.size)))")
            }
            console.line("(--dry-run: 실제로 받지는 않았습니다)")
            finish(code: ExitCode.ok)
            return
        }

        do {
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: tmpDir.path) { try fm.removeItem(at: tmpDir) }
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            console.line("저장 폴더를 만들 수 없습니다: \(destRoot.path)")
            console.line("  \(error.localizedDescription)")
            finish(code: ExitCode.error)
            return
        }

        for a in plan.adopted { man.record(key: a.key, relPath: a.relPath) }

        if plan.items.isEmpty {
            console.line()
            console.line("새로 받을 사진이 없습니다.")
            finish(code: ExitCode.ok)
            return
        }

        if let free = freeSpace(), free < plan.bytesToDownload + 500_000_000 {
            console.line()
            console.line("저장 공간이 부족합니다: 필요 \(formatBytes(plan.bytesToDownload)), 남은 공간 \(formatBytes(free)).")
            console.line("외장 디스크 폴더를 고르거나 --since 로 기간을 나눠 받으세요.")
            finish(code: ExitCode.noSpace)
            return
        }

        console.line()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "아이폰 사진 받는 중")
        pending = Array(0..<plan.items.count)
        pendingPos = 0
        phase = .downloading
        startedAt = Date()
        samples = [(t: startedAt, bytes: 0)]
        pump()
    }

    private func freeSpace() -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? destRoot.resourceValues(forKeys: keys) else { return nil }
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(v.volumeAvailableCapacity ?? 0)
        let best = max(important, plain)
        return best > 0 ? best : nil
    }

    // MARK: - 내려받기

    private func pump() {
        guard phase == .downloading, let cam = camera else { return }
        while !restricted && inFlight.count < opts.window && pendingPos < pending.count {
            let idx = pending[pendingPos]
            pendingPos += 1
            let item = plan.items[idx]
            let file = cameraFiles[item.media.id]
            let attempt = (attempts[idx] ?? 0) + 1
            attempts[idx] = attempt
            let tmpName = "\(idx)-\(attempt)-\(item.fileName)"
            tmpNames[idx] = tmpName
            inFlight[idx] = ObjectIdentifier(file)
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: tmpDir,
                .saveAsFilename: tmpName,
                .overwrite: true,
            ]
            cam.requestDownloadFile(file,
                                    options: options,
                                    downloadDelegate: self,
                                    didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                                    contextInfo: UnsafeMutableRawPointer(bitPattern: idx + 1))
        }
        if inFlight.isEmpty && pendingPos >= pending.count {
            allDone()
        }
    }

    func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: off_t, maxBytes: off_t) {
        partialBytes[ObjectIdentifier(file)] = Int64(downloadedBytes)
    }

    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        guard phase == .downloading else { return }
        var idx = contextInfo.map { Int(bitPattern: $0) - 1 } ?? -1
        if idx < 0 || idx >= plan.items.count {
            let oid = ObjectIdentifier(file)
            idx = inFlight.first(where: { $0.value == oid })?.key ?? -1
        }
        guard idx >= 0, let oid = inFlight.removeValue(forKey: idx) else {
            pump()
            return
        }
        partialBytes.removeValue(forKey: oid)
        partialBytes.removeValue(forKey: ObjectIdentifier(file))
        let item = plan.items[idx]
        let requested = tmpNames[idx] ?? item.fileName

        if let e = error {
            failedAttempt(idx, e.localizedDescription, tmpName: requested)
        } else {
            let saved = (options[ICDownloadOption.savedFilename.rawValue] as? String) ?? requested
            do {
                try place(item: item, from: tmpDir.appendingPathComponent(saved))
                doneCount += 1
                doneBytes += item.media.size
                failed.removeValue(forKey: idx)
            } catch {
                failedAttempt(idx, "저장 실패: \(error.localizedDescription)", tmpName: saved)
            }
        }
        reportProgress()
        pump()
    }

    /// tmp 에 받은 파일을 제자리로 옮기고 날짜를 찍은 뒤 받은 목록에 적는다.
    private func place(item: PlannedItem, from src: URL) throws {
        var finalName = item.fileName
        let savedExt = src.pathExtension
        let plannedExt = (finalName as NSString).pathExtension
        if !savedExt.isEmpty && savedExt.lowercased() != plannedExt.lowercased() {
            // 아이폰이 형식을 바꿔 보낸 경우(HEIC → JPG) 확장자를 실제 파일에 맞춘다.
            let base = (finalName as NSString).deletingPathExtension
            finalName = base + "." + savedExt
        }
        let dir = item.relDir.isEmpty ? destRoot : destRoot.appendingPathComponent(item.relDir, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var dst = dir.appendingPathComponent(finalName)
        var n = 2
        while fm.fileExists(atPath: dst.path) {
            dst = dir.appendingPathComponent(numberedName(finalName, n))
            n += 1
        }
        try fm.moveItem(at: src, to: dst)
        if let d = item.media.date {
            try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: dst.path)
        }
        manifest?.record(key: manifestKey(item.media), relPath: joinPath(item.relDir, dst.lastPathComponent))
    }

    private func failedAttempt(_ idx: Int, _ message: String, tmpName: String) {
        try? fm.removeItem(at: tmpDir.appendingPathComponent(tmpName))
        if restricted {
            // 잠겨서 실패한 것은 횟수에 넣지 않고 다시 줄 세운다.
            attempts[idx] = max(0, (attempts[idx] ?? 1) - 1)
            pending.append(idx)
            return
        }
        if (attempts[idx] ?? 0) < 2 {
            pending.append(idx)   // 맨 뒤에서 한 번 더
        } else {
            failed[idx] = message
        }
    }

    private func allDone() {
        console.clearStatus()
        printSummary()
        if opts.openWhenDone { openInFinder() }
        finish(code: failed.isEmpty ? ExitCode.ok : ExitCode.someFailed)
    }

    private func printSummary() {
        console.clearStatus()
        let elapsed = Date().timeIntervalSince(startedAt)
        let avg = elapsed > 0 ? Double(doneBytes) / elapsed : 0
        console.line("받음: \(formatCount(doneCount))개, \(formatBytes(doneBytes)) · 걸린 시간 \(formatDuration(elapsed)) · 평균 \(formatBytes(Int64(avg)))/s")
        if !failed.isEmpty {
            let url = stateDir.appendingPathComponent("failed.txt")
            var text = ""
            for (idx, msg) in failed.sorted(by: { $0.key < $1.key }) {
                let m = plan.items[idx].media
                text += "\(m.folder)/\(m.name)\t\(msg)\n"
            }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            console.line("받지 못한 것: \(formatCount(failed.count))개 → 목록 \(url.path)")
            console.line("  다시 실행하면 받지 못한 것만 다시 받습니다.")
        }
        console.line("저장 위치: \(destRoot.path)")
    }

    private func openInFinder() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [destRoot.path]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - 진행 표시

    private func startTicker() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        switch phase {
        case .cataloging:
            let pct = camera?.contentCatalogPercentCompleted ?? 0
            let el = Int(Date().timeIntervalSince(catalogStartedAt))
            console.status("목록 읽는 중 \(pct)% · \(formatCount(catalogItemCount))개 · 경과 \(el / 60)분 \(el % 60)초")
            if el >= 20 && pct == 0 && catalogItemCount == 0 && !restrictedNoticeShown {
                showRestrictedNotice()
            }
        case .downloading:
            reportProgress()
        default:
            break
        }
    }

    private func reportProgress() {
        guard phase == .downloading else { return }
        let now = Date()
        let current = doneBytes + partialBytes.values.reduce(0, +)
        if let last = samples.last, now.timeIntervalSince(last.t) >= 0.5 {
            samples.append((t: now, bytes: current))
        }
        while samples.count > 2, let first = samples.first, now.timeIntervalSince(first.t) > 10 {
            samples.removeFirst()
        }
        var speed = 0.0
        if let first = samples.first, now.timeIntervalSince(first.t) > 0.5 {
            speed = Double(current - first.bytes) / now.timeIntervalSince(first.t)
        }
        let total = plan.bytesToDownload
        let pct = total > 0 ? Double(current) / Double(total) * 100 : 100
        let remain = speed > 0 ? Double(total - current) / speed : Double.nan
        let lockNote = restricted ? " · 아이폰 잠금을 풀어 주세요" : ""
        let text = "받는 중 \(formatCount(doneCount))/\(formatCount(plan.items.count)) (\(String(format: "%.1f", pct))%) · "
            + "\(formatBytes(current))/\(formatBytes(total)) · \(formatBytes(Int64(speed)))/s · 남은 시간 \(formatDuration(remain))\(lockNote)"
        if console.isTTY {
            console.status(text)
        } else if now.timeIntervalSince(lastPlainReport) >= 10 {
            console.line(text)
            lastPlainReport = now
        }
    }

    private func showRestrictedNotice() {
        guard !restrictedNoticeShown else { return }
        restrictedNoticeShown = true
        console.line("아이폰 잠금을 풀어 주세요. 처음 연결이면 아이폰에 뜨는 '이 컴퓨터를 신뢰하겠습니까?'에서 '신뢰'를 누르세요.")
    }

    // MARK: - 끝

    private func deviceGone() {
        guard phase != .finished else { return }
        console.line()
        console.line("아이폰 연결이 끊어졌습니다. 다시 연결하고 실행하면 받은 것은 건너뛰고 이어서 받습니다.")
        if phase == .downloading { printSummary() }
        finish(code: ExitCode.disconnected)
    }

    private func finish(code: Int32) {
        guard phase != .finished else { return }
        phase = .finished
        searchTimer?.invalidate()
        tickTimer?.invalidate()
        console.clearStatus()
        manifest?.close()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        if fm.fileExists(atPath: tmpDir.path) { try? fm.removeItem(at: tmpDir) }
        camera?.requestCloseSession()
        browser.stop()
        // 세션 닫기 요청이 나갈 짬을 준 뒤 끝낸다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exit(code)
        }
    }
}
