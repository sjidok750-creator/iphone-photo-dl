// 아이폰 사진 받기 (iphone-photo-dl)
//   옵션 없이 실행(앱 아이콘 더블클릭) → 창(앱)
//   옵션을 주면 → 터미널 모드 (--help 참고)

import AppKit

let console = Console()
// 옛 macOS 는 Finder 에서 열 때 -psn_… 인자를 붙인다.
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

if arguments.isEmpty {
    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}

let options: Options
do {
    options = try parseArguments(Array(arguments))
} catch {
    console.line("오류: \(error)")
    exit(64)
}

if options.showHelp {
    console.line(helpText)
    exit(0)
}
if options.showVersion {
    console.line("iphone-photo-dl \(appVersion)")
    exit(0)
}
if options.selfTest {
    exit(runSelfTest(console) ? 0 : 1)
}

let runner = CLIRunner(options: options, console: console)

// Ctrl+C·창 닫기: 받은 목록을 정리하고 끝낸다(다시 실행하면 이어서 받음).
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { runner.interrupt() }
    src.resume()
    signalSources.append(src)
}

runner.start()
RunLoop.main.run()
