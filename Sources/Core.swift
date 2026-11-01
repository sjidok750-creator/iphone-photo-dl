// 기기와 상관없는 순수 로직: 옵션 해석, 저장 위치 계획, 받은 목록(매니페스트), 숫자 표시.
// ImageCaptureCore 를 쓰지 않으므로 --self-test 로 아이폰 없이 검사할 수 있다.

import Foundation

let appVersion = "0.11.0"
let appDisplayName = "아이폰 사진 받기"
let githubRepo = "sjidok750-creator/iphone-photo-dl"
let installCommand = "curl -fsSL https://raw.githubusercontent.com/\(githubRepo)/main/install.sh | bash"
let stateDirName = ".iphone-photo-dl"
let defaultDestination = NSString(string: "~/Pictures/iPhone").expandingTildeInPath

// MARK: - 옵션

enum Layout: String {
    case date    // 2024/2024-05/IMG_1234.HEIC
    case flat    // IMG_1234.HEIC
    case folder  // 100APPLE/IMG_1234.HEIC (아이폰 폴더 그대로)
}

enum KindFilter {
    case all, photos, videos
}

struct Options {
    var destination = defaultDestination
    var layout = Layout.date
    var kinds = KindFilter.all
    var since: Date?
    var limit: Int?
    var listOnly = false
    var dryRun = false
    var openWhenDone = false
    var requestOriginals = false   // 0.10: 기본은 끔(Big Sur 에서 효과 미확인) — 아이폰 '원본 유지' 설정에 맡긴다
    var timeout: Double = 60
    var window = 2
    var newestFirst = false
    var batchSize: Int?            // 최근 것부터 N장씩 받고, 확인 후 아이폰에서 지울지 묻기
    var showHelp = false
    var showVersion = false
    var selfTest = false
}

struct ArgError: Error, CustomStringConvertible {
    let description: String
}

let helpText = """
iphone-photo-dl \(appVersion) — 아이폰 사진·동영상을 Mac 으로 한꺼번에 받습니다.

사용법:
  iphone-photo-dl                 창(앱)으로 열기
  iphone-photo-dl --cli           터미널에서 ~/Pictures/iPhone 에 받기
  iphone-photo-dl [옵션] [저장폴더] 터미널에서 받기

  이미 받은 파일은 건너뛰므로, 다시 실행하면 새 사진만 받습니다.
  기록: ~/Library/Logs/iphone-photo-dl.log

옵션:
  --list              받지 않고 개수·용량만 보여 줍니다
  --dry-run           무엇을 어디에 받을지 목록만 보여 줍니다
  --layout date       연/월 폴더로 정리 (기본, 예: 2024/2024-05/)
  --layout flat       한 폴더에 모두
  --layout folder     아이폰 폴더 그대로 (100APPLE/ …)
  --since 2024-01-01  이 날짜(포함) 이후 찍은 것만
  --photos-only       사진만 (Live Photo 의 동영상 부분 제외)
  --videos-only       동영상만
  --limit 20          앞에서부터 이 개수만 (시험용)
  --newest-first      최근 사진부터 받기
  --batch 300         최근 사진부터 300장씩 받고, 맥에 저장된 것을 확인한 뒤
                      아이폰에서 지울지 묶음마다 묻기 (지우려면 y 입력)
  --request-originals 아이폰에 원본(변환 안 한 파일)을 달라고 요청 (시험용, 기본 끔)
  --window 2          한 번에 줄 세우는 파일 수 (1~8)
  --timeout 60        아이폰을 기다리는 시간(초)
  --open              끝나면 Finder 로 저장 폴더 열기
  --version           버전
  --help              이 도움말
"""

func parseDay(_ text: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    f.isLenient = false
    return f.date(from: text)
}

func parseArguments(_ args: [String]) throws -> Options {
    var o = Options()
    var i = 0
    var positional: [String] = []

    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw ArgError(description: "\(flag) 뒤에 값이 필요합니다") }
        return args[i]
    }

    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help": o.showHelp = true
        case "-v", "--version": o.showVersion = true
        case "--self-test": o.selfTest = true
        case "--list": o.listOnly = true
        case "--dry-run": o.dryRun = true
        case "--open": o.openWhenDone = true
        case "--cli": break   // 옵션 없이 터미널 모드로 받기
        case "--no-originals": o.requestOriginals = false   // 0.9 호환
        case "--request-originals": o.requestOriginals = true
        case "--newest-first": o.newestFirst = true
        case "--batch":
            let v = try value(a)
            guard let n = Int(v), (1...5000).contains(n) else { throw ArgError(description: "--batch 는 1~5000 장입니다 (입력: \(v))") }
            o.batchSize = n
            o.newestFirst = true
        case "--photos-only": o.kinds = .photos
        case "--videos-only": o.kinds = .videos
        case "--layout":
            let v = try value(a)
            guard let l = Layout(rawValue: v) else {
                throw ArgError(description: "--layout 은 date, flat, folder 중 하나입니다 (입력: \(v))")
            }
            o.layout = l
        case "--since":
            let v = try value(a)
            guard let d = parseDay(v) else {
                throw ArgError(description: "--since 날짜는 2024-01-31 꼴로 씁니다 (입력: \(v))")
            }
            o.since = d
        case "--limit":
            let v = try value(a)
            guard let n = Int(v), n > 0 else { throw ArgError(description: "--limit 은 1 이상의 정수입니다 (입력: \(v))") }
            o.limit = n
        case "--timeout":
            let v = try value(a)
            guard let n = Double(v), n > 0 else { throw ArgError(description: "--timeout 은 초 단위 양수입니다 (입력: \(v))") }
            o.timeout = n
        case "--window":
            let v = try value(a)
            guard let n = Int(v), (1...8).contains(n) else { throw ArgError(description: "--window 는 1~8 입니다 (입력: \(v))") }
            o.window = n
        default:
            if a.hasPrefix("-") && a.count > 1 {
                throw ArgError(description: "모르는 옵션: \(a)  (--help 로 사용법 보기)")
            }
            positional.append(a)
        }
        i += 1
    }

    if positional.count > 1 {
        throw ArgError(description: "저장폴더는 하나만 줄 수 있습니다: \(positional.joined(separator: ", "))")
    }
    if let p = positional.first {
        o.destination = NSString(string: p).expandingTildeInPath
    }
    if o.destination.count > 1 && o.destination.hasSuffix("/") {
        o.destination = String(o.destination.dropLast())
    }
    return o
}

// MARK: - 아이폰 항목

struct MediaInfo {
    let id: Int        // 원본 목록에서의 번호
    let name: String   // IMG_1234.HEIC
    let folder: String // 100APPLE
    let size: Int64
    let date: Date?
}

let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "avi"]

/// 기기 이름으로 아이폰·아이패드인지 본다(SD 카드 등 다른 카메라보다 먼저 고르려고).
func looksLikeAppleDevice(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.contains("iphone") || n.contains("ipad") || n.contains("ipod")
}

func isVideo(_ name: String) -> Bool {
    return videoExtensions.contains((name as NSString).pathExtension.lowercased())
}

func sanitizeFileName(_ name: String) -> String {
    var s = name.replacingOccurrences(of: "/", with: "_")
    s = s.replacingOccurrences(of: ":", with: "_")
    s = s.replacingOccurrences(of: "\t", with: " ")
    s = s.replacingOccurrences(of: "\n", with: " ")
    s = s.trimmingCharacters(in: .whitespaces)
    if s.isEmpty || s == "." || s == ".." { s = "unnamed" }
    return s
}

func relativeDirectory(for m: MediaInfo, layout: Layout, calendar: Calendar = Calendar.current) -> String {
    switch layout {
    case .flat:
        return ""
    case .folder:
        let f = sanitizeFileName(m.folder)
        return m.folder.isEmpty ? "기타" : f
    case .date:
        guard let d = m.date else { return "날짜 없음" }
        let c = calendar.dateComponents([.year, .month], from: d)
        let y = c.year ?? 0
        let mo = c.month ?? 0
        return String(format: "%04d/%04d-%02d", y, y, mo)
    }
}

func joinPath(_ dir: String, _ name: String) -> String {
    return dir.isEmpty ? name : dir + "/" + name
}

/// IMG_0001.HEIC → IMG_0001 (2).HEIC
func numberedName(_ name: String, _ n: Int) -> String {
    if n <= 1 { return name }
    let ns = name as NSString
    let ext = ns.pathExtension
    let base = ns.deletingPathExtension
    return ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
}

func manifestKey(_ m: MediaInfo) -> String {
    let t = m.date.map { Int64($0.timeIntervalSince1970.rounded()) } ?? 0
    return sanitizeFileName(m.folder) + "/" + sanitizeFileName(m.name) + "|" + String(m.size) + "|" + String(t)
}

// MARK: - 계획

struct PlannedItem {
    let media: MediaInfo
    let relDir: String
    let fileName: String
    var relPath: String { return joinPath(relDir, fileName) }
}

struct Plan {
    var items: [PlannedItem] = []
    var totalCount = 0             // 아이폰 전체
    var totalBytes: Int64 = 0
    var photoCount = 0
    var videoCount = 0
    var filteredOut = 0            // --since / --photos-only 등으로 뺀 것
    var alreadyInManifest = 0      // 전에 받은 것
    var adopted: [(key: String, relPath: String)] = []  // 같은 이름·크기 파일이 이미 있어 받은 것으로 친 것
    var present: [(media: MediaInfo, relPath: String)] = []  // 이미 맥에 있는 것(전에 받음 + 받은 것으로 침)
    var bytesToDownload: Int64 {
        return items.reduce(Int64(0)) { $0 + $1.media.size }
    }
}

/// 받을 목록을 만든다.
/// - existingSize: 저장폴더 기준 상대 경로의 파일 크기(없으면 nil)
func makePlan(media: [MediaInfo],
              options: Options,
              manifest: [String: String],
              existingSize: (String) -> Int64?) -> Plan {
    var plan = Plan()
    plan.totalCount = media.count
    for m in media {
        plan.totalBytes += m.size
        if isVideo(m.name) { plan.videoCount += 1 } else { plan.photoCount += 1 }
    }

    // 오래된 것부터. 날짜 없는 것은 맨 뒤.
    let sorted = media.sorted { a, b in
        switch (a.date, b.date) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default:
            if a.folder != b.folder { return a.folder < b.folder }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
    }

    // 매니페스트가 가리키는 파일(다른 항목 몫)은 남이 쓰지 않게 한다.
    var taken = Set(manifest.values.map { $0.lowercased() })

    for m in sorted {
        if let since = options.since, let d = m.date, d < since { plan.filteredOut += 1; continue }
        switch options.kinds {
        case .photos where isVideo(m.name): plan.filteredOut += 1; continue
        case .videos where !isVideo(m.name): plan.filteredOut += 1; continue
        default: break
        }

        let key = manifestKey(m)
        if let rp = manifest[key], existingSize(rp) != nil {
            plan.alreadyInManifest += 1
            plan.present.append((media: m, relPath: rp))
            continue
        }

        let dir = relativeDirectory(for: m, layout: options.layout)
        let base = sanitizeFileName(m.name)
        var n = 1
        while true {
            let name = numberedName(base, n)
            let rp = joinPath(dir, name)
            let lower = rp.lowercased()  // Mac 디스크는 보통 대소문자를 가리지 않는다
            if taken.contains(lower) { n += 1; continue }
            if let s = existingSize(rp) {
                if s == m.size {
                    // 다른 도구로 이미 받은 같은 파일
                    plan.adopted.append((key: key, relPath: rp))
                    plan.present.append((media: m, relPath: rp))
                    taken.insert(lower)
                    break
                }
                n += 1
                continue
            }
            plan.items.append(PlannedItem(media: m, relDir: dir, fileName: name))
            taken.insert(lower)
            break
        }
    }
    // 이름은 늘 오래된 것부터 정해(모드와 상관없이 같은 이름), 받는 순서만 바꾼다.
    if options.newestFirst {
        plan.items = sortNewestFirst(plan.items) { $0.media }
    }
    if let limit = options.limit, plan.items.count > limit {
        plan.items = Array(plan.items.prefix(limit))
    }
    return plan
}

/// 최근 것부터, 날짜 없는 것은 맨 뒤 (같으면 원래 순서)
func sortNewestFirst<T>(_ list: [T], _ media: (T) -> MediaInfo) -> [T] {
    return list.enumerated().sorted { a, b in
        let x = media(a.element).date, y = media(b.element).date
        switch (x, y) {
        case let (p?, q?) where p != q: return p > q
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.offset < b.offset
        }
    }.map { $0.element }
}

// MARK: - 묶음 (최근 것부터 N장씩 받고 지우기)

/// 같은 사진에 딸린 파일을 한 묶음으로: IMG_1234.HEIC · IMG_1234.MOV(Live Photo) · IMG_E1234.HEIC(편집본) · IMG_O1234.AAE
func assetGroupKey(_ m: MediaInfo) -> String {
    var base = (m.name as NSString).deletingPathExtension
    if let r = base.range(of: "^([A-Za-z]+_)[EO]([0-9]+)$", options: .regularExpression) {
        let s = String(base[r])
        if let us = s.firstIndex(of: "_") {
            let prefix = s[...us]
            let digits = s[s.index(us, offsetBy: 2)...]
            base = String(prefix) + String(digits)
        }
    }
    return sanitizeFileName(m.folder) + "/" + base.uppercased()
}

/// 사진(묶음) 단위로 최근 것부터 size 장씩 나눈다. 한 사진에 딸린 파일은 같은 묶음에 들어간다.
func makeBatches(_ media: [MediaInfo], size: Int) -> [[MediaInfo]] {
    var groups: [String: [MediaInfo]] = [:]
    var order: [String] = []
    for m in media {
        let k = assetGroupKey(m)
        if groups[k] == nil { order.append(k) }
        groups[k, default: []].append(m)
    }
    struct G { let files: [MediaInfo]; let date: Date?; let first: Int }
    var list: [G] = []
    for (i, k) in order.enumerated() {
        let files = groups[k]!
        let date = files.compactMap { $0.date }.max()
        list.append(G(files: files, date: date, first: i))
    }
    let sorted = list.sorted { a, b in
        switch (a.date, b.date) {
        case let (p?, q?) where p != q: return p > q
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.first < b.first
        }
    }
    var batches: [[MediaInfo]] = []
    var i = 0
    let n = max(1, size)
    while i < sorted.count {
        let chunk = sorted[i..<min(i + n, sorted.count)]
        batches.append(chunk.flatMap { $0.files })
        i += n
    }
    return batches
}

/// 묶음 안 사진(묶음 키) 개수
func photoCount(_ files: [MediaInfo]) -> Int {
    return Set(files.map { assetGroupKey($0) }).count
}

// MARK: - 받은 목록 (저장폴더/.iphone-photo-dl/manifest.tsv)

final class Manifest {
    let url: URL
    private(set) var entries: [String: String] = [:]
    private var handle: FileHandle?

    init(stateDirectory: URL) {
        url = stateDirectory.appendingPathComponent("manifest.tsv")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { entries[String(parts[0])] = String(parts[1]) }
            }
        }
    }

    func record(key: String, relPath: String) {
        entries[key] = relPath
        let line = key + "\t" + relPath + "\n"
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
        }
        handle?.write(line.data(using: .utf8)!)
    }

    func close() {
        handle?.synchronizeFile()
        handle?.closeFile()
        handle = nil
    }
}

// MARK: - 버전

/// "v0.10.2" 가 "0.9.1" 보다 새것인가 (숫자 마디별 비교)
func isNewerVersion(_ remote: String, than local: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        return t.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }
    let a = parts(remote), b = parts(local)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

func systemDescription() -> String {
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x86_64"
    #endif
    return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(arch)"
}

// MARK: - 표시

func formatBytes(_ bytes: Int64) -> String {
    // Finder 와 같이 1000 단위
    let b = Double(bytes)
    if b < 1000 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var v = b
    var i = -1
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
}

func formatCount(_ n: Int) -> String {
    let s = String(n < 0 ? -n : n)
    var out = ""
    for (i, ch) in s.reversed().enumerated() {
        if i > 0 && i % 3 == 0 { out.append(",") }
        out.append(ch)
    }
    return (n < 0 ? "-" : "") + String(out.reversed())
}

func formatDuration(_ seconds: Double) -> String {
    if !seconds.isFinite || seconds < 0 { return "계산 중" }
    let s = Int(seconds.rounded())
    if s < 60 { return "1분 이내" }
    let minutes = (s + 59) / 60
    let h = minutes / 60
    let m = minutes % 60
    if h == 0 { return "\(m)분" }
    return m == 0 ? "\(h)시간" : "\(h)시간 \(m)분"
}
