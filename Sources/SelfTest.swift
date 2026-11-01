// --self-test: 아이폰 없이 순수 로직과 프레임워크 적재를 검사한다(빌드 서버에서 실행).

import Foundation

func runSelfTest(_ console: Console) -> Bool {
    var total = 0
    var failures = 0
    func check(_ ok: Bool, _ label: String, line: Int = #line) {
        total += 1
        if !ok {
            failures += 1
            console.line("실패: \(label) (SelfTest.swift:\(line))")
        }
    }

    // 프레임워크가 실제로 실리는지
    check(NSClassFromString("ICDeviceBrowser") != nil, "ImageCaptureCore 적재")

    // 표시
    check(formatBytes(0) == "0 B", "bytes 0")
    check(formatBytes(999) == "999 B", "bytes 999")
    check(formatBytes(1500) == "1.5 KB", "bytes 1500")
    check(formatBytes(123_400_000) == "123 MB", "bytes 123.4M")
    check(formatBytes(15_300_000_000) == "15.3 GB", "bytes 15.3G")
    check(formatCount(0) == "0", "count 0")
    check(formatCount(999) == "999", "count 999")
    check(formatCount(1000) == "1,000", "count 1000")
    check(formatCount(1_234_567) == "1,234,567", "count 1234567")
    check(formatDuration(30) == "1분 이내", "dur 30")
    check(formatDuration(120) == "2분", "dur 120")
    check(formatDuration(3600) == "1시간", "dur 3600")
    check(formatDuration(3660) == "1시간 1분", "dur 3660")
    check(formatDuration(7199) == "2시간", "dur 7199")
    check(formatDuration(Double.nan) == "계산 중", "dur nan")

    // 이름
    check(numberedName("IMG_0001.HEIC", 1) == "IMG_0001.HEIC", "numbered 1")
    check(numberedName("IMG_0001.HEIC", 2) == "IMG_0001 (2).HEIC", "numbered 2")
    check(numberedName("README", 3) == "README (3)", "numbered no ext")
    check(isVideo("IMG_1.MOV") && isVideo("a.mp4") && !isVideo("IMG_1.HEIC") && !isVideo("IMG_1.JPG"), "isVideo")
    check(looksLikeAppleDevice("홍길동의 iPhone") && looksLikeAppleDevice("IPAD") && !looksLikeAppleDevice("NO NAME") && !looksLikeAppleDevice("Canon EOS"), "apple device name")
    check(sanitizeFileName("a/b:c") == "a_b_c", "sanitize")
    check(sanitizeFileName("  ") == "unnamed", "sanitize empty")

    // 폴더 배치
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let may3 = Date(timeIntervalSince1970: 1_714_694_400)  // 2024-05-03 00:00 UTC
    let m = MediaInfo(id: 0, name: "IMG_1.HEIC", folder: "100APPLE", size: 10, date: may3)
    check(relativeDirectory(for: m, layout: .date, calendar: utc) == "2024/2024-05", "layout date")
    check(relativeDirectory(for: m, layout: .flat, calendar: utc) == "", "layout flat")
    check(relativeDirectory(for: m, layout: .folder, calendar: utc) == "100APPLE", "layout folder")
    let noDate = MediaInfo(id: 1, name: "x.JPG", folder: "", size: 1, date: nil)
    check(relativeDirectory(for: noDate, layout: .date) == "날짜 없음", "layout no date")
    check(relativeDirectory(for: noDate, layout: .folder) == "기타", "layout no folder")

    // 옵션
    if let o = try? parseArguments(["--layout", "flat", "--since", "2024-01-31", "--limit", "5", "--photos-only", "/tmp/out/"]) {
        check(o.layout == .flat, "arg layout")
        check(o.limit == 5, "arg limit")
        check(o.destination == "/tmp/out", "arg dest")
        check(o.since != nil, "arg since")
        check(o.kinds == .photos, "arg photos")
    } else {
        check(false, "arg parse")
    }
    check((try? parseArguments(["--layout", "x"])) == nil, "arg bad layout")
    check((try? parseArguments(["--bogus"])) == nil, "arg unknown")
    check((try? parseArguments(["a", "b"])) == nil, "arg two dest")
    check((try? parseArguments(["--since", "2024-13-01"])) == nil, "arg bad date")
    check((try? parseArguments(["--limit"])) == nil, "arg missing value")
    check((try? parseArguments([]))?.destination.hasSuffix("/Pictures/iPhone") == true, "arg default dest")
    check((try? parseArguments([]))?.requestOriginals == false, "arg originals default off")
    check((try? parseArguments(["--request-originals"]))?.requestOriginals == true, "arg request-originals")
    check((try? parseArguments(["--no-originals"]))?.requestOriginals == false, "arg no-originals (0.9 호환)")
    check((try? parseArguments(["--cli"]))?.destination == defaultDestination, "arg cli")
    check((try? parseArguments([]))?.window == 2, "arg window default")

    // 버전 비교 (새 버전 알림)
    check(isNewerVersion("v0.10.0", than: "0.9.1"), "ver 0.10 > 0.9.1")
    check(isNewerVersion("v1.0.0", than: "0.10.0"), "ver 1.0 > 0.10")
    check(!isNewerVersion("v0.10.0", than: "0.10.0"), "ver same")
    check(!isNewerVersion("v0.9.9", than: "0.10.0"), "ver older")
    check(isNewerVersion("0.10.1", than: "0.10"), "ver patch")

    // 계획: 날짜는 시간대와 상관없게 각 달 15일 정오(UTC)
    func day(_ y: Int, _ mo: Int, hour: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = 15; c.hour = hour
        return utc.date(from: c)!
    }
    let media = [
        MediaInfo(id: 0, name: "IMG_0001.HEIC", folder: "100APPLE", size: 100, date: day(2024, 1, hour: 10)),
        MediaInfo(id: 1, name: "IMG_0001.HEIC", folder: "110APPLE", size: 200, date: day(2024, 1, hour: 11)),
        MediaInfo(id: 2, name: "IMG_0002.MOV", folder: "100APPLE", size: 300, date: day(2024, 2)),
        MediaInfo(id: 3, name: "IMG_0003.HEIC", folder: "100APPLE", size: 400, date: day(2024, 3)),
        MediaInfo(id: 4, name: "IMG_0004.HEIC", folder: "100APPLE", size: 500, date: day(2024, 3)),
        MediaInfo(id: 5, name: "IMG_0005.HEIC", folder: "100APPLE", size: 600, date: day(2024, 3)),
        MediaInfo(id: 6, name: "IMG_0006.JPG", folder: "100APPLE", size: 700, date: nil),
    ]
    func dirOf(_ d: Date) -> String { return relativeDirectory(for: MediaInfo(id: 0, name: "", folder: "", size: 0, date: d), layout: .date) }
    let jan = dirOf(day(2024, 1)), feb = dirOf(day(2024, 2)), mar = dirOf(day(2024, 3))
    let manifestEntries = [manifestKey(media[3]): mar + "/IMG_0003.HEIC"]
    let onDisk: [String: Int64] = [
        mar + "/IMG_0003.HEIC": 400,   // 받은 목록에 있음 → 건너뜀
        mar + "/IMG_0004.HEIC": 500,   // 목록엔 없지만 같은 크기 → 받은 것으로 침
        mar + "/IMG_0005.HEIC": 999,   // 다른 파일 → (2)
    ]
    var opt = Options()
    let p = makePlan(media: media, options: opt, manifest: manifestEntries) { onDisk[$0] }
    let expected = [
        jan + "/IMG_0001.HEIC",
        jan + "/IMG_0001 (2).HEIC",
        feb + "/IMG_0002.MOV",
        mar + "/IMG_0005 (2).HEIC",
        "날짜 없음/IMG_0006.JPG",
    ]
    check(p.items.map { $0.relPath } == expected, "plan paths \(p.items.map { $0.relPath })")
    check(p.alreadyInManifest == 1, "plan manifest skip")
    check(p.adopted.count == 1 && p.adopted.first?.relPath == mar + "/IMG_0004.HEIC", "plan adopted")
    check(p.photoCount == 6 && p.videoCount == 1 && p.totalCount == 7, "plan counts")
    check(p.totalBytes == 2800, "plan total bytes")
    check(p.bytesToDownload == 100 + 200 + 300 + 600 + 700, "plan bytes to download")

    opt.kinds = .photos
    let pPhotos = makePlan(media: media, options: opt, manifest: [:]) { _ in nil }
    check(pPhotos.items.count == 6 && pPhotos.filteredOut == 1, "plan photos-only")

    opt.kinds = .all
    opt.since = day(2024, 2, hour: 0)
    let pSince = makePlan(media: media, options: opt, manifest: [:]) { _ in nil }
    check(pSince.filteredOut == 2 && pSince.items.count == 5, "plan since (날짜 없는 것은 포함)")

    opt.since = nil
    opt.limit = 2
    let pLimit = makePlan(media: media, options: opt, manifest: [:]) { _ in nil }
    check(pLimit.items.count == 2, "plan limit")

    opt.limit = nil
    opt.layout = .folder
    let pFolder = makePlan(media: media, options: opt, manifest: [:]) { _ in nil }
    check(pFolder.items.first?.relPath == "100APPLE/IMG_0001.HEIC" && pFolder.items[1].relPath == "110APPLE/IMG_0001.HEIC", "plan folder layout")

    // 받은 목록 저장·다시 읽기
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("ipdl-selftest-\(getpid())", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let man = Manifest(stateDirectory: tmp)
    man.record(key: "100APPLE/IMG_1.HEIC|10|0", relPath: "2024/2024-05/IMG_1.HEIC")
    man.record(key: "k2", relPath: "날짜 없음/b c.mov")
    man.close()
    let man2 = Manifest(stateDirectory: tmp)
    check(man2.entries.count == 2, "manifest count")
    check(man2.entries["100APPLE/IMG_1.HEIC|10|0"] == "2024/2024-05/IMG_1.HEIC", "manifest value")
    check(man2.entries["k2"] == "날짜 없음/b c.mov", "manifest unicode/space")
    man2.record(key: "k3", relPath: "x")
    man2.close()
    check(Manifest(stateDirectory: tmp).entries.count == 3, "manifest append")
    try? fm.removeItem(at: tmp)

    console.line("자체 검사: \(total)건 중 실패 \(failures)건")
    return failures == 0
}
