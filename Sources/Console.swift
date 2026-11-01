// 터미널 출력. 진행 줄은 같은 줄을 덮어 쓰고(터미널일 때만), 일반 줄은 그 위에 찍는다.

import Foundation

final class Console {
    let isTTY = isatty(STDOUT_FILENO) == 1
    private var statusShown = false

    func line(_ s: String = "") {
        clearStatus()
        write(s + "\n")
    }

    func status(_ s: String) {
        guard isTTY else { return }
        write("\r\u{1B}[2K" + s)
        statusShown = true
    }

    func clearStatus() {
        if statusShown {
            write("\r\u{1B}[2K")
            statusShown = false
        }
    }

    private func write(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8)!)
    }
}
