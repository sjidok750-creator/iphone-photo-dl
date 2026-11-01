// 문제를 나중에 살펴볼 수 있게 남기는 기록: ~/Library/Logs/iphone-photo-dl.log
// 앱의 '기록 보기' 단추가 이 파일을 연다.

import Foundation

final class Log {
    static let shared = Log()

    let url: URL
    private var handle: FileHandle?
    private let stamp: DateFormatter

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        url = dir.appendingPathComponent("iphone-photo-dl.log")
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 5 MB 가 넘으면 .old 로 돌린다
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 5_000_000 {
            let old = dir.appendingPathComponent("iphone-photo-dl.old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ text: String) {
        let line = stamp.string(from: Date()) + "  " + text + "\n"
        if let d = line.data(using: .utf8) { handle?.write(d) }
    }

    func flush() {
        handle?.synchronizeFile()
    }
}

/// NSError 를 기록용 한 줄로: 도메인·코드·설명
func describeError(_ error: Error) -> String {
    let ns = error as NSError
    var s = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        s += " (원인 \(under.domain) \(under.code))"
    }
    return s
}
