import CoreGraphics

enum TouchKey: String, CaseIterable, Identifiable {
    case command, option, control, shift, returnKey, escape
    static var modifiers: [TouchKey] { [.command, .option, .control, .shift] }
    var isModifier: Bool { Self.modifiers.contains(self) }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .command: "Command ⌘"
        case .option: "Option ⌥"
        case .control: "Control ⌃"
        case .shift: "Shift ⇧"
        case .returnKey: "Return ↩"
        case .escape: "Esc ⎋"
        }
    }
    var keyCode: CGKeyCode {
        switch self {
        case .command: 55
        case .option: 58
        case .control: 59
        case .shift: 56
        case .returnKey: 36
        case .escape: 53
        }
    }
    var flag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .option: .maskAlternate
        case .control: .maskControl
        case .shift: .maskShift
        case .returnKey, .escape: []
        }
    }
    var usages: Set<UInt32> {
        switch self {
        case .command: [0xe3, 0xe7]
        case .option: [0xe2, 0xe6]
        case .control: [0xe0, 0xe4]
        case .shift: [0xe1, 0xe5]
        case .returnKey: [0x28]
        case .escape: [0x29]
        }
    }
}

struct TouchBindings: Equatable {
    var two: TouchKey? = .control
    var three: TouchKey? = .command
    var four: TouchKey? = .option

    subscript(count: Int) -> TouchKey? {
        switch count {
        case 2: two
        case 3: three
        case 4: four
        default: nil
        }
    }
}
