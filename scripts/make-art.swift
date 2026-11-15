// 앱 아이콘(1024px PNG)과 DMG 배경 그림을 그린다.  사용: swift make-art.swift <icon.png> <dmg-background.png>
import AppKit

func png(_ w: Int, _ h: Int, _ path: String, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    draw(g.cgContext)
    g.flushGraphics()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}

// 아이콘: Apple 격자에 맞춘 둥근 사각형 + 흰 링크 기호
png(1024, 1024, CommandLine.arguments[1]) { c in
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    c.addPath(shape); c.setFillColor(NSColor.black.cgColor); c.fillPath()
    c.restoreGState()
    c.addPath(shape); c.clip()
    let colors = [NSColor(red: 0.20, green: 0.62, blue: 1.0, alpha: 1).cgColor, NSColor(red: 0.16, green: 0.30, blue: 0.86, alpha: 1).cgColor]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let img = symbol("link", size: 430, weight: .bold, color: .white)
    let s = img.size
    img.draw(in: CGRect(x: 512 - s.width / 2, y: 512 - s.height / 2, width: s.width, height: s.height))
}

// DMG 배경(660x400): 앱 -> 응용 프로그램 폴더 화살표와 안내 문구
png(660, 400, CommandLine.arguments[2]) { c in
    c.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
    c.fill(CGRect(x: 0, y: 0, width: 660, height: 400))
    let arrow = symbol("arrow.right", size: 54, weight: .semibold, color: NSColor(white: 0.62, alpha: 1))
    let s = arrow.size
    arrow.draw(in: CGRect(x: 330 - s.width / 2, y: 215 - s.height / 2, width: s.width, height: s.height))
    let text = "Copypaste를 응용 프로그램 폴더로 끌어다 놓으세요" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.35, alpha: 1)]
    let ts = text.size(withAttributes: attrs)
    text.draw(at: CGPoint(x: 330 - ts.width / 2, y: 52), withAttributes: attrs)
}
