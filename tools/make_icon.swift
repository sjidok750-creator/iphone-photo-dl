// 앱 아이콘(1024×1024 PNG)을 그린다: swift tools/make_icon.swift 출력.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let px = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let s = CGFloat(px)
let box = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
let shape = NSBezierPath(roundedRect: box, xRadius: s * 0.18, yRadius: s * 0.18)
let top = NSColor(calibratedRed: 0.22, green: 0.62, blue: 1.00, alpha: 1)
let bottom = NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.95, alpha: 1)
NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)

// 휴대폰 테두리
NSColor.white.setStroke()
let phone = NSBezierPath(roundedRect: NSRect(x: s * 0.34, y: s * 0.30, width: s * 0.32, height: s * 0.52),
                         xRadius: s * 0.05, yRadius: s * 0.05)
phone.lineWidth = s * 0.03
phone.stroke()
// 화면 속 사진(산과 해)
NSColor.white.setFill()
let mountain = NSBezierPath()
mountain.move(to: NSPoint(x: s * 0.39, y: s * 0.52))
mountain.line(to: NSPoint(x: s * 0.47, y: s * 0.64))
mountain.line(to: NSPoint(x: s * 0.52, y: s * 0.58))
mountain.line(to: NSPoint(x: s * 0.56, y: s * 0.62))
mountain.line(to: NSPoint(x: s * 0.61, y: s * 0.52))
mountain.close()
mountain.fill()
NSBezierPath(ovalIn: NSRect(x: s * 0.535, y: s * 0.68, width: s * 0.06, height: s * 0.06)).fill()
// 아래로 받는 화살표
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: s * 0.50, y: s * 0.12 + s * 0.06))
arrow.line(to: NSPoint(x: s * 0.42, y: s * 0.26))
arrow.line(to: NSPoint(x: s * 0.47, y: s * 0.26))
arrow.line(to: NSPoint(x: s * 0.47, y: s * 0.36))
arrow.line(to: NSPoint(x: s * 0.53, y: s * 0.36))
arrow.line(to: NSPoint(x: s * 0.53, y: s * 0.26))
arrow.line(to: NSPoint(x: s * 0.58, y: s * 0.26))
arrow.close()
NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.25, alpha: 1).setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
