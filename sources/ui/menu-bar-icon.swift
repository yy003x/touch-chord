import AppKit

@MainActor
enum MenuBarIcon {
    static let idle = make(key: nil)
    private static let active = Dictionary(uniqueKeysWithValues: TouchKey.allCases.map { ($0, make(key: $0)) })

    static func image(for key: TouchKey?) -> NSImage {
        key.flatMap { active[$0] } ?? idle
    }

    private static func make(key: TouchKey?) -> NSImage {
        let symbolName: String? = switch key {
        case .command: "command"
        case .option: "option"
        case .control: "control"
        case .shift: "shift"
        case .returnKey: "return"
        case .escape: "escape"
        case nil: nil
        }
        let symbol = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let pad = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 2.25, width: 16.5, height: 13.5),
                                   xRadius: 3, yRadius: 3)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            pad.lineWidth = 1.25
            if let symbol {
                pad.fill()
                // 从底图扣出键位符号，模板图像由系统适配浅色、深色和高亮状态。
                let bounds = NSRect(x: 3.5, y: 4, width: 11, height: 10)
                let scale = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height)
                let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                       width: size.width, height: size.height),
                            from: .zero, operation: .destinationOut, fraction: 1)
            } else {
                pad.stroke()
                for x in [5.0, 9.0, 13.0] {
                    NSBezierPath(ovalIn: NSRect(x: x - 0.9, y: 8.6, width: 1.8, height: 1.8)).fill()
                }
                NSBezierPath(roundedRect: NSRect(x: 6, y: 5, width: 6, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
