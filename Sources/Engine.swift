// 아이폰 연결·내려받기 엔진. 창(앱)과 터미널(CLI)이 같이 쓴다.
// macOS 기본 프레임워크 ImageCaptureCore('이미지 캡처' 앱과 같은 통로)만 쓴다.
//
// 순서: 기기 찾기 → 세션 열기 → 전체 목록(카탈로그) → 계획 → 줄 세워 내려받기
// 잘 되게 하려고 넣은 것
//   · 감시: 전송이 일정 시간 멈추면 그 파일을 취소하고 다시 시도, 두 번 멈춘 파일은 건너뜀,
//           연달아 세 번 멈추면 멈추고 '케이블을 뺐다 다시 꽂기' 안내 (세션을 저절로 다시 열지는 않음)
//   · 잠금: 아이폰이 잠기면 새 요청을 멈추고, 풀리면 이어서
//   · 사진 앱·이미지 캡처 앱이 아이폰을 함께 붙잡으면 닫고 화면에 알림
//   · 아이폰이 변환해서 보내면(HEIC → JPG) 바로 '원본 유지' 안내
//   · 모든 오류를 ~/Library/Logs/iphone-photo-dl.log 에 도메인·코드와 함께 기록
// 받은 파일은 저장폴더/.iphone-photo-dl/tmp 에 먼저 받고, 끝나면 제자리로 옮긴 뒤 받은 목록에 적는다.

import Foundation
import AppKit
import CoreGraphics
import ImageCaptureCore

enum Stage: Equatable {
    case searching     // 아이폰을 기다림
    case connecting    // 세션 여는 중
    case cataloging    // 목록 읽는 중
    case planned       // 계획만(터미널 --list / --dry-run)
    case downloading
    case paused        // 사용자가 멈춤
    case confirmDelete // 묶음을 받고 확인함 — 아이폰에서 지울지 묻는 중
    case deleting      // 아이폰에서 지우는 중
    case finished
    case failed(String)
}

/// 한 묶음을 받고 맥에 저장된 것을 확인한 결과
struct BatchSummary {
    let number: Int            // 몇 번째 묶음 (1부터)
    let count: Int             // 전체 묶음 수
    let photos: Int            // 확인된 사진(묶음) 수 = 지울 수 있는 것
    let files: Int             // 그 파일 수 (Live Photo 동영상·편집본 포함)
    let bytes: Int64
    let newest: Date?
    let oldest: Date?
    let unverifiedPhotos: Int  // 맥에 저장이 확인되지 않아 지우지 않을 사진 수
    let deletable: [MediaInfo]
}

enum Notice: Hashable {
    case converting    // 아이폰이 변환해서 보냄
    case iCloudOn      // iCloud 사진 사용 중
    case closedApps    // 사진/이미지 캡처 앱을 닫음
    case stalled       // 전송이 멈춰 다시 시도함
    case manyErrors    // 연달아 오류
}

enum FailureKind { case connection, storage }

struct EngineConfig {
    var destination: String
    var layout = Layout.date
    var kinds = KindFilter.all
    var since: Date?
    var limit: Int?
    var window = 2
    var requestOriginals = false
    var planOnly = false
    var quitInterferingApps = true
    var newestFirst = false
    var batchSize: Int?        // 있으면: 최근 것부터 N장씩 받고, 확인 후 지울지 묻기
}

final class Engine: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {

    // MARK: 밖에서 보는 상태

    var onChange: (() -> Void)?
    var onMessage: ((String) -> Void)?

    private(set) var config: EngineConfig
    private(set) var stage = Stage.searching
    private(set) var deviceName = ""
    private(set) var isLocked = false
    private(set) var catalogPercent = 0
    private(set) var catalogCount = 0
    private(set) var plan = Plan()
    private(set) var jobTotalCount = 0
    private(set) var jobTotalBytes: Int64 = 0
    private(set) var doneCount = 0
    private(set) var doneBytes: Int64 = 0
    private(set) var speed: Double = 0
    private(set) var notices = Set<Notice>()
    private(set) var everConnected = false
    private(set) var disconnects = 0
    private(set) var failureKind = FailureKind.connection
    private(set) var lastResult: String?
    private(set) var closedAppNames: [String] = []
    private(set) var failed: [String: (display: String, reason: String)] = [:]
    private(set) var batches: [[MediaInfo]] = []
    private(set) var batchIndex = 0
    private(set) var batchSummary: BatchSummary?
    private(set) var sessionDoneCount = 0     // 이번 실행에서 받은 파일 (묶음을 넘어 누적)
    private(set) var sessionDoneBytes: Int64 = 0
    private(set) var deletedFiles = 0
    private(set) var deletedPhotos = 0
    private(set) var deleteFailures = 0
    private(set) var deleteBlockedHint: String?
    private(set) var iCloudOn = false

    var batchMode: Bool { return config.batchSize != nil && !config.planOnly }
    var destination: String { return config.destination }
    var failedCount: Int { return failed.count }
    var currentBytes: Int64 { return doneBytes + partial.values.reduce(0, +) }
    var remainingSeconds: Double {
        return speed > 0 ? Double(max(0, jobTotalBytes - currentBytes)) / speed : .nan
    }
    var elapsed: Double { return Date().timeIntervalSince(jobStartedAt) }
    var isBusy: Bool {
        switch stage {
        case .connecting, .cataloging, .downloading, .paused, .confirmDelete, .deleting: return true
        default: return false
        }
    }

    // MARK: 속

    private let fm = FileManager.default
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var fallbackCamera: ICCameraDevice?
    private var fallbackTimer: Timer?
    private var tickTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?

    private var cameraFiles: [ICCameraFile] = []
    private var removedItems = Set<ObjectIdentifier>()
    private var manifest: Manifest?
    private var resumeJob = false

    private var pending: [Int] = []          // plan.items 번호
    private var pendingPos = 0
    private var requests: [Int: Int] = [:]   // 요청 번호 → plan.items 번호
    private var requestFile: [Int: ObjectIdentifier] = [:]
    private var requestTmp: [Int: String] = [:]
    private var nextRequestId = 1
    private var partial: [ObjectIdentifier: Int64] = [:]
    private var attempts: [Int: Int] = [:]
    private var stallsByKey: [String: Int] = [:]
    private var consecutiveStalls = 0
    private var consecutiveErrors = 0
    private var openRetries = 0

    private var lastProgressAt = Date()
    private var catalogStartedAt = Date()
    private var lastCatalogChangeAt = Date()
    private var slowCatalogNoticeShown = false
    private var jobStartedAt = Date()
    private var samples: [(t: Date, bytes: Int64)] = []
    private var lastMilestone = 0
    private var deleteStartedAt = Date()

    private let interferingApps: Set<String> = ["com.apple.Photos", "com.apple.Image_Capture"]

    private var destRoot: URL { return URL(fileURLWithPath: config.destination, isDirectory: true) }
    private var stateDir: URL { return destRoot.appendingPathComponent(stateDirName, isDirectory: true) }
    private var tmpDir: URL { return stateDir.appendingPathComponent("tmp", isDirectory: true) }
    var failedListURL: URL { return stateDir.appendingPathComponent("failed.txt") }
    var deletedListURL: URL { return stateDir.appendingPathComponent("deleted.tsv") }

    init(config: EngineConfig) {
        self.config = config
        super.init()
    }

    // MARK: - 바깥에서 부르는 것

    func start() {
        log("=== \(appDisplayName) \(appVersion) 시작 · \(systemDescription()) · 저장 \(config.destination)")
        log("설정: 줄 \(config.window) · 원본 요청 \(config.requestOriginals ? "켬" : "끔") · 배치 \(config.layout.rawValue)"
            + (batchMode ? " · 최근 것부터 \(config.batchSize!)장씩 받고 지울지 묻기" : ""))
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.appLaunched(note)
        }
        changed()
    }

    func pause() {
        guard stage == .downloading else { return }
        stage = .paused
        log("사용자가 멈춤")
        changed()
    }

    func resume() {
        guard stage == .paused else { return }
        stage = .downloading
        lastProgressAt = Date()
        log("사용자가 계속")
        changed()
        pump()
    }

    /// '다시 받기' / '다시 시도'
    func retry() {
        log("다시 시도")
        failed.removeAll()
        stallsByKey.removeAll()
        consecutiveStalls = 0
        consecutiveErrors = 0
        notices.remove(.stalled)
        notices.remove(.manyErrors)
        resumeJob = false
        guard let cam = camera else {
            stage = .searching
            changed()
            return
        }
        if cameraFiles.isEmpty {
            // 목록을 못 읽은 상태: 세션부터 다시
            openRetries = 0
            stage = .connecting
            changed()
            cam.requestOpenSession()
        } else {
            planAndStart()
        }
    }

    /// 최근 것부터 N장씩 받고 지울지 묻기 (nil = 끔)
    func setBatchMode(_ size: Int?) {
        guard !isBusy else { return }
        config.batchSize = size
        log("묶음 모드: \(size.map { "\($0)장씩" } ?? "끔")")
        if camera != nil && !cameraFiles.isEmpty {
            failed.removeAll()
            resumeJob = false
            planAndStart()
        } else {
            changed()
        }
    }

    /// 확인한 묶음을 아이폰에서 지운다 (맥에 저장이 확인된 파일만)
    func deleteCurrentBatch() {
        guard stage == .confirmDelete, let s = batchSummary, let cam = camera else { return }
        var items: [ICCameraItem] = []
        var byObject: [ObjectIdentifier: MediaInfo] = [:]
        for m in s.deletable where m.id < cameraFiles.count {
            let f = cameraFiles[m.id]
            items.append(f)
            byObject[ObjectIdentifier(f)] = m
        }
        guard !items.isEmpty else {
            nextBatch()
            return
        }
        stage = .deleting
        deleteStartedAt = Date()
        log("지우기 요청: 묶음 \(s.number)/\(s.count), 사진 \(s.photos)장, 파일 \(items.count)개")
        changed()
        _ = cam.requestDeleteFiles(items, deleteFailed: { [weak self] failures in
            DispatchQueue.main.async {
                for (reason, item) in failures {
                    self?.log("지우기 실패: \(item.name ?? "?") (\(reason.rawValue))")
                }
            }
        }, completion: { [weak self] results, error in
            DispatchQueue.main.async {
                self?.deleteFinished(results: results, error: error, summary: s, byObject: byObject)
            }
        })
    }

    /// 지우지 않고 다음 묶음으로
    func keepCurrentBatch() {
        guard stage == .confirmDelete else { return }
        log("묶음 \(batchIndex + 1): 지우지 않음")
        nextBatch()
    }

    /// 묶음 그만 (지금까지로 끝)
    func stopBatches() {
        guard stage == .confirmDelete else { return }
        log("묶음 그만")
        complete()
    }

    func setDestination(_ path: String) {
        guard !(stage == .downloading || stage == .paused || stage == .cataloging || stage == .connecting) else { return }
        manifest?.close()
        manifest = nil
        config.destination = path
        log("저장 위치 바꿈: \(path)")
        if camera != nil && !cameraFiles.isEmpty {
            failed.removeAll()
            resumeJob = false
            planAndStart()
        } else {
            changed()
        }
    }

    func shutdown() {
        log("끝냄")
        tickTimer?.invalidate()
        fallbackTimer?.invalidate()
        if let o = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        endActivity()
        manifest?.close()
        removeTmp()
        camera?.requestCloseSession()
        browser.stop()
        Log.shared.flush()
    }

    // MARK: - 기기 찾기

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice else { return }
        guard stage == .searching || isFailedStage else { return }
        log("기기 발견: \(cam.name ?? "?")")
        if looksLikeAppleDevice(cam.name ?? "") {
            use(cam)
        } else if fallbackCamera == nil {
            // SD 카드 같은 다른 카메라는 잠시 기다려 아이폰이 없을 때만 쓴다.
            fallbackCamera = cam
            fallbackTimer?.invalidate()
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                guard let self = self, self.camera == nil, let c = self.fallbackCamera else { return }
                self.use(c)
            }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if let cam = camera, device === cam { deviceGone() }
        if let f = fallbackCamera, device === f {
            fallbackCamera = nil
            fallbackTimer?.invalidate()
        }
    }

    private var isFailedStage: Bool {
        if case .failed = stage { return true }
        return false
    }

    private func use(_ cam: ICCameraDevice) {
        camera = cam
        fallbackTimer?.invalidate()
        fallbackCamera = nil
        everConnected = true
        deviceName = cam.name ?? "이름 없는 기기"
        stage = .connecting
        isLocked = false
        openRetries = 0
        message("연결됨: \(deviceName)")
        quitInterferingApps()
        cam.delegate = self
        if config.requestOriginals {
            if cam.responds(to: #selector(setter: ICCameraDevice.mediaPresentation)) {
                cam.mediaPresentation = .originalAssets
                log("원본 요청: 적용")
            } else {
                log("원본 요청: 이 macOS 에 기능 없음")
            }
        }
        changed()
        cam.requestOpenSession()
    }

    private func deviceGone() {
        guard camera != nil else { return }
        disconnects += 1
        if isBusy && stage != .connecting && stage != .cataloging { resumeJob = true }
        batchSummary = nil
        message("아이폰 연결이 끊어졌습니다. 다시 꽂으면 받은 것은 건너뛰고 이어서 받습니다.")
        clearRequests()
        cameraFiles = []
        camera = nil
        deviceName = ""
        isLocked = false
        endActivity()
        stage = .searching
        changed()
    }

    // MARK: - 다른 앱

    private func quitInterferingApps() {
        guard config.quitInterferingApps else { return }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, interferingApps.contains(id) {
                closeApp(app)
            }
        }
    }

    private func appLaunched(_ note: Notification) {
        guard config.quitInterferingApps, camera != nil, isBusy else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, interferingApps.contains(id) else { return }
        closeApp(app)
    }

    private func closeApp(_ app: NSRunningApplication) {
        let name = app.localizedName ?? app.bundleIdentifier ?? "앱"
        if app.terminate() {
            notices.insert(.closedApps)
            if !closedAppNames.contains(name) { closedAppNames.append(name) }
            message("'\(name)' 앱이 아이폰을 함께 붙잡지 않도록 닫았습니다.")
        } else {
            log("'\(name)' 닫기 실패")
        }
    }

    // MARK: - ICDeviceDelegate

    func didRemove(_ device: ICDevice) {
        if let cam = camera, device === cam { deviceGone() }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let cam = camera, device === cam else { return }
        if let e = error {
            log("세션 열기 실패: \(describeError(e))")
            if openRetries < 2 {
                openRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self = self, self.camera === cam else { return }
                    cam.requestOpenSession()
                }
                return
            }
            fail("아이폰에 연결하지 못했습니다. 케이블을 뺐다 다시 꽂아 주세요.\n(\(e.localizedDescription))", kind: .connection)
            return
        }
        guard stage == .connecting else { return }
        stage = .cataloging
        catalogStartedAt = Date()
        lastCatalogChangeAt = Date()
        catalogPercent = 0
        catalogCount = 0
        slowCatalogNoticeShown = false
        if cam.responds(to: #selector(getter: ICCameraDevice.isAccessRestrictedAppleDevice)),
           cam.isAccessRestrictedAppleDevice {
            setLocked(true)
        }
        message("사진 목록을 읽는 중… (사진이 많으면 몇 분 걸립니다)")
        changed()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if let e = error { log("세션 닫기 오류: \(describeError(e))") }
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        if let e = error { log("기기 오류: \(describeError(e))") }
    }

    // MARK: - ICCameraDeviceDelegate

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        if stage == .cataloging || stage == .connecting {
            catalogCount += items.count
            lastCatalogChangeAt = Date()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        for i in items { removedItems.insert(ObjectIdentifier(i)) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard let cam = camera, device === cam else { return }
        setLocked(true)
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard let cam = camera, device === cam else { return }
        setLocked(false)
    }

    private func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        if locked {
            message("아이폰 잠금을 풀어 주세요. 처음 연결이면 아이폰에서 '이 컴퓨터를 신뢰'를 누르세요.")
        } else {
            message("아이폰 잠금이 풀렸습니다. 이어서 진행합니다.")
            lastProgressAt = Date()
            lastCatalogChangeAt = Date()
        }
        changed()
        if !locked && stage == .downloading { pump() }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard let cam = camera, device === cam, stage == .cataloging || stage == .connecting else { return }
        catalogReady(cam)
    }

    private func catalogReady(_ cam: ICCameraDevice) {
        cameraFiles = (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        let took = Date().timeIntervalSince(catalogStartedAt)
        message("목록 읽기 끝: \(formatCount(cameraFiles.count))개 (\(formatDuration(took)))")
        if cam.responds(to: #selector(getter: ICCameraDevice.iCloudPhotosEnabled)), cam.iCloudPhotosEnabled {
            notices.insert(.iCloudOn)
            iCloudOn = true
            log("iCloud 사진 켜짐")
        }
        log("기기 기능: \(cam.capabilities.joined(separator: ", "))")
        deleteBlockedHint = nil
        if cam.responds(to: #selector(getter: ICCameraDevice.isLocked)), cam.isLocked {
            deleteBlockedHint = "이 아이폰은 지금 지우기를 막고 있다고 알려 왔습니다. '아이폰에서 지우기'를 눌러도 지워지지 않을 수 있습니다."
            log("지우기 잠김(isLocked) = 예")
        }
        planAndStart()
    }

    // MARK: - 계획

    private func planAndStart() {
        // 아이폰에서 지워진 것(이 앱이 지웠거나 다른 데서 지움)은 목록에서 뺀다.
        if !removedItems.isEmpty {
            cameraFiles = cameraFiles.filter { !removedItems.contains(ObjectIdentifier($0)) }
            removedItems.removeAll()
        }
        var media: [MediaInfo] = []
        media.reserveCapacity(cameraFiles.count)
        for (i, f) in cameraFiles.enumerated() {
            media.append(MediaInfo(id: i,
                                   name: f.name ?? "unnamed",
                                   folder: f.parentFolder?.name ?? "",
                                   size: Int64(f.fileSize),
                                   date: f.creationDate ?? f.modificationDate))
        }
        let man = manifest ?? Manifest(stateDirectory: stateDir)
        manifest = man
        var opts = Options()
        opts.layout = config.layout
        // 묶음(지우기) 모드에서는 거르지 않는다: 사진의 일부만 받고 지우면 안 받은 파일까지 지워질 수 있다.
        opts.kinds = batchMode ? .all : config.kinds
        opts.since = batchMode ? nil : config.since
        opts.limit = batchMode ? nil : config.limit
        opts.newestFirst = config.newestFirst || batchMode
        let root = destRoot
        let fm = self.fm
        plan = makePlan(media: media, options: opts, manifest: man.entries) { rel in
            let path = root.appendingPathComponent(rel).path
            guard let a = try? fm.attributesOfItem(atPath: path),
                  (a[.type] as? FileAttributeType) == .typeRegular else { return nil }
            return (a[.size] as? NSNumber)?.int64Value
        }
        message("아이폰 전체: \(formatCount(plan.totalCount))개 (사진 \(formatCount(plan.photoCount)) · 동영상 \(formatCount(plan.videoCount))), \(formatBytes(plan.totalBytes))")
        if plan.alreadyInManifest + plan.adopted.count > 0 {
            message("이미 받은 것: \(formatCount(plan.alreadyInManifest + plan.adopted.count))개 → 건너뜀")
        }
        if plan.filteredOut > 0 { message("조건으로 뺀 것: \(formatCount(plan.filteredOut))개") }
        message("받을 것: \(formatCount(plan.items.count))개, \(formatBytes(plan.bytesToDownload))")
        message("저장 위치: \(config.destination)")

        if config.planOnly {
            stage = .planned
            changed()
            return
        }
        if batchMode {
            setupBatches()
        } else {
            beginDownloading()
        }
    }

    private func prepareFolders() -> Bool {
        do {
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            removeTmp()
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            log("폴더 만들기 실패: \(describeError(error))")
            fail("저장 폴더를 만들 수 없습니다: \(config.destination)\n\(error.localizedDescription)", kind: .storage)
            return false
        }
        for a in plan.adopted { manifest?.record(key: a.key, relPath: a.relPath) }
        return true
    }

    private func beginDownloading() {
        guard prepareFolders() else { return }

        if plan.items.isEmpty {
            if !resumeJob {
                jobTotalCount = 0
                jobTotalBytes = 0
                doneCount = 0
                doneBytes = 0
            }
            complete()
            return
        }
        if let free = freeSpace(), free < plan.bytesToDownload + 500_000_000 {
            fail("저장 공간이 부족합니다: 필요 \(formatBytes(plan.bytesToDownload)), 남은 공간 \(formatBytes(free)).\n'바꾸기'로 외장 디스크 폴더를 고르세요.", kind: .storage)
            return
        }

        if resumeJob {
            // 끊겼다 다시 이어 받는 중: 진행률이 이어지게 한다
            jobTotalCount = doneCount + plan.items.count
            jobTotalBytes = doneBytes + plan.bytesToDownload
        } else {
            jobTotalCount = plan.items.count
            jobTotalBytes = plan.bytesToDownload
            doneCount = 0
            doneBytes = 0
            jobStartedAt = Date()
            lastMilestone = 0
        }
        message("받기 시작: \(formatCount(plan.items.count))개, \(formatBytes(plan.bytesToDownload))")
        startQueue(Array(plan.items.indices))
    }

    private func startQueue(_ indices: [Int]) {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "아이폰 사진 받는 중")
        }
        pending = indices
        pendingPos = 0
        attempts = [:]
        consecutiveStalls = 0
        consecutiveErrors = 0
        samples = [(t: Date(), bytes: currentBytes)]
        lastProgressAt = Date()
        stage = .downloading
        changed()
        pump()
    }

    // MARK: - 묶음: 최근 것부터 N장씩 받기 → 맥에서 확인 → 지울지 묻기

    private func setupBatches() {
        guard prepareFolders() else { return }
        let size = config.batchSize ?? 300
        let candidates = plan.items.map { $0.media } + plan.present.map { $0.media }
        batches = makeBatches(candidates, size: size)
        batchIndex = 0
        if !resumeJob {
            sessionDoneCount = 0
            sessionDoneBytes = 0
            deletedFiles = 0
            deletedPhotos = 0
            deleteFailures = 0
            jobStartedAt = Date()
        }
        resumeJob = false
        message("최근 사진부터 \(size)장씩: 사진 \(formatCount(photoCount(candidates)))장, \(formatCount(batches.count))묶음")
        startBatch()
    }

    private func startBatch() {
        guard batchIndex < batches.count else {
            complete()
            return
        }
        batchSummary = nil
        let batch = batches[batchIndex]
        let ids = Set(batch.map { $0.id })
        let indices = plan.items.indices.filter { ids.contains(plan.items[$0].media.id) }
        let bytes = indices.reduce(Int64(0)) { $0 + plan.items[$1].media.size }
        jobTotalCount = indices.count
        jobTotalBytes = bytes
        doneCount = 0
        doneBytes = 0
        lastMilestone = 0
        message("묶음 \(batchIndex + 1)/\(batches.count): 사진 \(photoCount(batch))장 — 새로 받을 파일 \(formatCount(indices.count))개, \(formatBytes(bytes))")
        if indices.isEmpty {
            batchDownloaded()
            return
        }
        if let free = freeSpace(), free < bytes + 500_000_000 {
            fail("저장 공간이 부족합니다: 필요 \(formatBytes(bytes)), 남은 공간 \(formatBytes(free)).\n'바꾸기'로 외장 디스크 폴더를 고르세요.", kind: .storage)
            return
        }
        startQueue(indices)
    }

    /// 묶음을 다 받았으면 사진마다 맥에 저장된 것을 확인하고, 지울지 묻는다.
    private func batchDownloaded() {
        let batch = batches[batchIndex]
        var groups: [String: [MediaInfo]] = [:]
        for m in batch { groups[assetGroupKey(m), default: []].append(m) }
        var deletable: [MediaInfo] = []
        var unverified = 0
        var bytes: Int64 = 0
        for (key, files) in groups {
            if files.allSatisfy({ verifiedOnDisk($0) }) {
                deletable += files
                bytes += files.reduce(Int64(0)) { $0 + $1.size }
            } else {
                unverified += 1
                log("맥에 저장 확인 안 됨 → 지우지 않음: \(key)")
            }
        }
        let dates = deletable.compactMap { $0.date }
        batchSummary = BatchSummary(number: batchIndex + 1, count: batches.count,
                                    photos: groups.count - unverified, files: deletable.count, bytes: bytes,
                                    newest: dates.max(), oldest: dates.min(),
                                    unverifiedPhotos: unverified, deletable: deletable)
        endActivity()
        stage = .confirmDelete
        var text = "묶음 \(batchIndex + 1)/\(batches.count): 사진 \(formatCount(groups.count - unverified))장(파일 \(formatCount(deletable.count))개, \(formatBytes(bytes)))이 맥에 저장된 것을 확인했습니다."
        if unverified > 0 { text += " 확인되지 않은 \(unverified)장은 지우지 않습니다." }
        message(text)
        changed()
    }

    /// 받은 목록에 있고, 그 파일이 실제로 있고, 크기가 맞는가
    private func verifiedOnDisk(_ m: MediaInfo) -> Bool {
        guard let rel = manifest?.entries[manifestKey(m)] else { return false }
        let path = destRoot.appendingPathComponent(rel).path
        guard let a = try? fm.attributesOfItem(atPath: path),
              (a[.type] as? FileAttributeType) == .typeRegular,
              let size = (a[.size] as? NSNumber)?.int64Value, size > 0 else { return false }
        if size == m.size { return true }
        // 아이폰이 변환해서 보낸 파일(확장자가 바뀜)은 크기가 원래와 다르다
        return (rel as NSString).pathExtension.lowercased() != (m.name as NSString).pathExtension.lowercased()
    }

    private func deleteFinished(results: [ICDeleteResult: [ICCameraItem]], error: Error?,
                                summary s: BatchSummary, byObject: [ObjectIdentifier: MediaInfo]) {
        guard stage == .deleting else {
            log("늦은 지우기 결과(무시): 성공 \(results[.successful]?.count ?? 0)")
            return
        }
        let ok = results[.successful] ?? []
        let bad = (results[.failed] ?? []).count + (results[.canceled] ?? []).count
        if let e = error { log("지우기 오류: \(describeError(e))") }

        let stamp = ISO8601DateFormatter().string(from: Date())
        var text = ""
        var okKeys = Set<String>()
        for item in ok {
            let oid = ObjectIdentifier(item)
            removedItems.insert(oid)
            if let m = byObject[oid] {
                okKeys.insert(manifestKey(m))
                text += "\(stamp)\t\(m.folder)/\(m.name)\t\(manifest?.entries[manifestKey(m)] ?? "")\n"
            }
        }
        if !text.isEmpty {
            if !fm.fileExists(atPath: deletedListURL.path) {
                fm.createFile(atPath: deletedListURL.path, contents: nil)
            }
            if let h = try? FileHandle(forWritingTo: deletedListURL), let d = text.data(using: .utf8) {
                h.seekToEndOfFile()
                h.write(d)
                h.closeFile()
            }
        }
        var groups: [String: [MediaInfo]] = [:]
        for m in s.deletable { groups[assetGroupKey(m), default: []].append(m) }
        let photosGone = groups.values.filter { $0.allSatisfy { okKeys.contains(manifestKey($0)) } }.count
        deletedFiles += ok.count
        deletedPhotos += photosGone
        deleteFailures += bad
        message("아이폰에서 지움: 사진 \(formatCount(photosGone))장(파일 \(formatCount(ok.count))개)" + (bad > 0 ? " · 지우지 못함 \(bad)개" : ""))
        if ok.isEmpty && s.files > 0 {
            deleteBlockedHint = "아이폰이 지우기를 받아들이지 않았습니다. 아이폰 잠금을 풀고 다시 해 보세요. iCloud 사진이 켜져 있으면 케이블로는 지울 수 없을 수 있습니다."
            message(deleteBlockedHint!)
        }
        nextBatch()
    }

    private func nextBatch() {
        batchIndex += 1
        startBatch()
    }

    private func freeSpace() -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? destRoot.resourceValues(forKeys: keys) else { return nil }
        let best = max(v.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v.volumeAvailableCapacity ?? 0))
        return best > 0 ? best : nil
    }

    // MARK: - 내려받기

    private func pump() {
        guard stage == .downloading, !isLocked, let cam = camera else { return }
        while requests.count < config.window && pendingPos < pending.count {
            let idx = pending[pendingPos]
            pendingPos += 1
            let item = plan.items[idx]
            guard item.media.id < cameraFiles.count else { continue }
            if failed[manifestKey(item.media)] != nil { continue }
            let file = cameraFiles[item.media.id]
            let rid = nextRequestId
            nextRequestId += 1
            attempts[idx] = (attempts[idx] ?? 0) + 1
            if requests.isEmpty { lastProgressAt = Date() }
            requests[rid] = idx
            requestFile[rid] = ObjectIdentifier(file)
            let tmpName = "\(rid)-\(item.fileName)"
            requestTmp[rid] = tmpName
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: tmpDir,
                .saveAsFilename: tmpName,
                .overwrite: true,
            ]
            cam.requestDownloadFile(file,
                                    options: options,
                                    downloadDelegate: self,
                                    didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                                    contextInfo: UnsafeMutableRawPointer(bitPattern: rid))
        }
        if requests.isEmpty && pendingPos >= pending.count {
            if batchMode {
                batchDownloaded()
            } else {
                complete()
            }
        }
    }

    func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: off_t, maxBytes: off_t) {
        let oid = ObjectIdentifier(file)
        if requestFile.values.contains(oid) {
            partial[oid] = Int64(downloadedBytes)
            lastProgressAt = Date()
        }
    }

    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        let rid = contextInfo.map { Int(bitPattern: $0) } ?? -1
        guard let idx = requests.removeValue(forKey: rid) else {
            // 감시가 이미 취소한 요청의 늦은 답
            if let e = error { log("늦은 답(무시): \(file.name ?? "?") \(describeError(e))") }
            return
        }
        if let oid = requestFile.removeValue(forKey: rid) { partial.removeValue(forKey: oid) }
        let requested = requestTmp.removeValue(forKey: rid) ?? ""
        lastProgressAt = Date()
        let item = plan.items[idx]
        let key = manifestKey(item.media)

        if let e = error {
            log("받기 실패 \(item.media.folder)/\(item.media.name) (\(attempts[idx] ?? 0)번째): \(describeError(e))")
            consecutiveErrors += 1
            if consecutiveErrors >= 10 && !notices.contains(.manyErrors) {
                notices.insert(.manyErrors)
                message("받기 실패가 이어집니다. 아이폰 설정 > 사진 > 'Mac 또는 PC로 전송'을 '원본 유지'로 바꿔 보세요.")
            }
            failedAttempt(idx, reason: e.localizedDescription, tmpName: requested)
        } else {
            let saved = (options[ICDownloadOption.savedFilename.rawValue] as? String) ?? requested
            do {
                try place(item: item, from: tmpDir.appendingPathComponent(saved))
                doneCount += 1
                doneBytes += item.media.size
                sessionDoneCount += 1
                sessionDoneBytes += item.media.size
                failed.removeValue(forKey: key)
                consecutiveStalls = 0
                consecutiveErrors = 0
                if doneCount - lastMilestone >= 500 {
                    lastMilestone = doneCount
                    log("진행: \(doneCount)/\(jobTotalCount) · \(formatBytes(doneBytes))")
                }
            } catch {
                log("저장 실패 \(item.media.name): \(describeError(error))")
                failedAttempt(idx, reason: "저장 실패: \(error.localizedDescription)", tmpName: saved)
            }
        }
        changed()
        if stage == .downloading { pump() }
    }

    /// tmp 에 받은 파일을 제자리로 옮기고 날짜를 찍은 뒤 받은 목록에 적는다.
    private func place(item: PlannedItem, from src: URL) throws {
        var finalName = item.fileName
        let savedExt = src.pathExtension
        let plannedExt = (finalName as NSString).pathExtension
        if !savedExt.isEmpty && savedExt.lowercased() != plannedExt.lowercased() {
            // 아이폰이 형식을 바꿔 보냄(HEIC → JPG): 느려지는 원인이라 바로 안내한다.
            if !notices.contains(.converting) {
                notices.insert(.converting)
                message("아이폰이 사진을 변환하며 보내고 있어 느립니다. 아이폰 설정 > 사진 > 'Mac 또는 PC로 전송'을 '원본 유지'로 바꾸면 빨라집니다.")
                log("변환 감지: \(item.fileName) → .\(savedExt)")
            }
            finalName = (finalName as NSString).deletingPathExtension + "." + savedExt
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

    private func failedAttempt(_ idx: Int, reason: String, tmpName: String) {
        if !tmpName.isEmpty { try? fm.removeItem(at: tmpDir.appendingPathComponent(tmpName)) }
        if isLocked {
            // 잠겨서 실패한 것은 횟수에 넣지 않고 다시 줄 세운다.
            attempts[idx] = max(0, (attempts[idx] ?? 1) - 1)
            pending.append(idx)
            return
        }
        if (attempts[idx] ?? 0) < 3 {
            pending.append(idx)
        } else {
            let m = plan.items[idx].media
            failed[manifestKey(m)] = (display: "\(m.folder)/\(m.name)", reason: reason)
        }
    }

    // MARK: - 감시 (0.5초마다)

    private func tick() {
        let now = Date()
        switch stage {
        case .cataloging:
            guard let cam = camera else { break }
            let p = cam.contentCatalogPercentCompleted
            if p != catalogPercent {
                catalogPercent = p
                lastCatalogChangeAt = now
            }
            // 준비 신호가 오지 않아도 100% 이고 목록이 있으면 진행한다.
            if p >= 100, now.timeIntervalSince(catalogStartedAt) > 5, now.timeIntervalSince(lastCatalogChangeAt) > 5,
               (cam.mediaFiles?.count ?? 0) > 0 {
                log("준비 신호 없이 목록 100% — 진행")
                catalogReady(cam)
                return
            }
            if !slowCatalogNoticeShown && !isLocked && now.timeIntervalSince(lastCatalogChangeAt) > 120 {
                slowCatalogNoticeShown = true
                log("목록 읽기 2분간 변화 없음 (\(catalogPercent)%, \(catalogCount)개)")
                message("목록 읽기가 오래 걸립니다. 아이폰 잠금을 풀어 두고 기다려 주세요. 5분 넘게 그대로면 케이블을 뺐다 다시 꽂아 주세요.")
            }
        case .downloading:
            updateSpeed(now)
            if !isLocked && !requests.isEmpty {
                let largest = requests.values.map { plan.items[$0].media.size }.max() ?? 0
                let limit = max(60, Double(largest) / 2_000_000)   // 최저 2 MB/s 를 가정한 여유
                let quiet = now.timeIntervalSince(lastProgressAt)
                if quiet > limit { handleStall(seconds: Int(quiet)) }
            }
        case .deleting:
            if now.timeIntervalSince(deleteStartedAt) > 300 {
                log("지우기 응답 없음 5분 → 다음 묶음")
                deleteBlockedHint = "아이폰이 지우기에 답하지 않았습니다. 아이폰 잠금을 풀어 두고, 끝난 뒤 아이폰 사진 앱에서 지워졌는지 확인해 주세요."
                message(deleteBlockedHint!)
                nextBatch()
                return
            }
        default:
            break
        }
        changed()
    }

    private func handleStall(seconds: Int) {
        consecutiveStalls += 1
        notices.insert(.stalled)
        // 진행 중이던 파일: 받은 바이트가 있는 것, 없으면 가장 먼저 요청한 것
        let activeRid = requests.keys.first(where: { rid in
            guard let oid = requestFile[rid] else { return false }
            return (partial[oid] ?? 0) > 0
        }) ?? requests.keys.min()
        var requeue: [Int] = []
        for (rid, idx) in requests.sorted(by: { $0.key < $1.key }) {
            if let t = requestTmp[rid] { try? fm.removeItem(at: tmpDir.appendingPathComponent(t)) }
            let m = plan.items[idx].media
            let key = manifestKey(m)
            if rid == activeRid {
                stallsByKey[key] = (stallsByKey[key] ?? 0) + 1
                log("전송 멈춤 \(seconds)초: \(m.folder)/\(m.name) (\(formatBytes(m.size)), 이 파일 \(stallsByKey[key]!)번째, 연속 \(consecutiveStalls))")
                if stallsByKey[key]! >= 2 {
                    failed[key] = (display: "\(m.folder)/\(m.name)", reason: "전송이 계속 멈춤")
                    message("'\(m.name)' 은(는) 전송이 계속 멈춰 건너뜁니다.")
                    continue
                }
            } else {
                attempts[idx] = max(0, (attempts[idx] ?? 1) - 1)
            }
            requeue.append(idx)
        }
        clearRequests()
        camera?.cancelDownload()
        pending.insert(contentsOf: requeue, at: pendingPos)

        if consecutiveStalls >= 3 {
            fail("아이폰과의 전송이 멈췄습니다.\n아이폰이 잠겨 있으면 잠금을 풀고(자동 잠금 '안 함' 권장), 그래도 안 되면 케이블을 뺐다 다시 꽂아 주세요. 받은 것은 건너뛰고 이어서 받습니다.", kind: .connection)
            return
        }
        message("전송이 \(seconds)초 동안 멈춰서 다시 시도합니다.")
        lastProgressAt = Date()
        // 취소가 새 요청까지 지우지 않게 잠깐 기다렸다 다시 줄 세운다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.lastProgressAt = Date()
            self?.pump()
        }
    }

    private func updateSpeed(_ now: Date) {
        let cur = currentBytes
        if let last = samples.last, now.timeIntervalSince(last.t) >= 0.5 {
            samples.append((t: now, bytes: cur))
        }
        while samples.count > 2, let first = samples.first, now.timeIntervalSince(first.t) > 10 {
            samples.removeFirst()
        }
        if let first = samples.first, now.timeIntervalSince(first.t) > 1 {
            speed = max(0, Double(cur - first.bytes) / now.timeIntervalSince(first.t))
        }
    }

    // MARK: - 끝

    private func complete() {
        stage = .finished
        resumeJob = false
        endActivity()
        removeTmp()
        manifest?.close()
        manifest = nil
        if !failed.isEmpty {
            var text = ""
            for (_, v) in failed.sorted(by: { $0.value.display < $1.value.display }) {
                text += "\(v.display)\t\(v.reason)\n"
            }
            try? text.write(to: failedListURL, atomically: true, encoding: .utf8)
        }
        let el = Date().timeIntervalSince(jobStartedAt)
        let avg = el > 0 ? Double(doneBytes) / el : 0
        if batchMode {
            var text = "끝: 받음 \(formatCount(sessionDoneCount))개(\(formatBytes(sessionDoneBytes))) · 아이폰에서 지움 사진 \(formatCount(deletedPhotos))장(파일 \(formatCount(deletedFiles))개)"
            if deleteFailures > 0 { text += " · 지우지 못함 \(deleteFailures)개" }
            message(text)
            if deletedFiles > 0 { message("지운 파일 목록: \(deletedListURL.path)") }
            lastResult = "지난번: \(formatCount(sessionDoneCount))개 받음 · 아이폰에서 \(formatCount(deletedPhotos))장 지움"
            if !failed.isEmpty {
                message("받지 못한 것: \(formatCount(failed.count))개 → 목록 \(failedListURL.path)")
            }
        } else if jobTotalCount == 0 {
            message("새로 받을 사진이 없습니다. (이미 모두 받음)")
            lastResult = "지난번: 새 사진 없음 (이미 모두 받음)"
        } else {
            message("받음: \(formatCount(doneCount))개, \(formatBytes(doneBytes)) · 걸린 시간 \(formatDuration(el)) · 평균 \(formatBytes(Int64(avg)))/s")
            lastResult = "지난번: \(formatCount(doneCount))개 받음"
            if !failed.isEmpty {
                message("받지 못한 것: \(formatCount(failed.count))개 → 목록 \(failedListURL.path)")
                lastResult! += " · \(formatCount(failed.count))개 받지 못함"
            }
        }
        Log.shared.flush()
        changed()
    }

    private func fail(_ text: String, kind: FailureKind) {
        log("문제: \(text.replacingOccurrences(of: "\n", with: " "))")
        failureKind = kind
        clearRequests()
        endActivity()
        removeTmp()
        manifest?.close()
        manifest = nil
        stage = .failed(text)
        onMessage?(text)
        Log.shared.flush()
        changed()
    }

    private func clearRequests() {
        requests.removeAll()
        requestFile.removeAll()
        requestTmp.removeAll()
        partial.removeAll()
    }

    private func removeTmp() {
        if fm.fileExists(atPath: tmpDir.path) { try? fm.removeItem(at: tmpDir) }
    }

    private func endActivity() {
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func message(_ text: String) {
        log(text)
        onMessage?(text)
    }

    private func log(_ text: String) {
        Log.shared.write(text)
    }

    private func changed() {
        onChange?()
    }
}
