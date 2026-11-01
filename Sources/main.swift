// iphone-photo-dl — 아이폰 사진·동영상을 Mac 으로 한꺼번에 받는 명령줄 도구.

import Foundation

let console = Console()

let options: Options
do {
    options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
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

let importer = Importer(options: options, console: console)

// Ctrl+C: 받은 목록을 정리하고 끝낸다(다시 실행하면 이어서 받음).
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { importer.interrupt() }
    src.resume()
    signalSources.append(src)
}

importer.start()
RunLoop.main.run()
