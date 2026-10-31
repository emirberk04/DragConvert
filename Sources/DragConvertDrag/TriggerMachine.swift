import DragConvertCore

/// Sürükleme sırasında basılı tetik tuşları.
public struct TriggerModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = TriggerModifiers(rawValue: 1 << 0)
    public static let option = TriggerModifiers(rawValue: 1 << 1)
    public static let control = TriggerModifiers(rawValue: 1 << 2)
}

/// Sürükleme ve tuş olaylarından halkanın ne zaman açılıp kapanacağına karar verir.
///
/// Kurallar:
/// - Halka sadece dosya sürüklenirken açılır.
/// - Tek bir tetik tuşu basılıysa onun modu açılır. Birden çok tuş basılıysa açık mod korunur (bir tuşu
///   bırakmadan diğerine geçerken titreme olmasın); halka kapalıysa öncelik ⇧, ⌥, ⌃.
/// - Hiçbir tetik tuşu basılı değilse halka kapanır ve sürükleme normal devam eder.
public struct TriggerMachine: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case dragging
        case open(RingMode)
    }

    public enum Action: Sendable, Equatable {
        case open(RingMode)
        case switchMode(RingMode)
        case close
    }

    public private(set) var phase: Phase = .idle
    public var bindings: [RingMode: TriggerModifiers]

    public init(bindings: [RingMode: TriggerModifiers] = [.convert: .shift, .tools: .option, .actions: .control]) {
        self.bindings = bindings
    }

    public mutating func dragBegan(modifiers: TriggerModifiers) -> Action? {
        phase = .dragging
        return modifiersChanged(modifiers)
    }

    public mutating func modifiersChanged(_ modifiers: TriggerModifiers) -> Action? {
        guard phase != .idle else { return nil }
        let held = RingMode.allCases.filter { mode in
            guard let binding = bindings[mode] else { return false }
            return modifiers.contains(binding)
        }

        switch phase {
        case .idle:
            return nil
        case .dragging:
            guard let mode = held.first else { return nil }
            phase = .open(mode)
            return .open(mode)
        case .open(let current):
            if held.isEmpty {
                phase = .dragging
                return .close
            }
            if held.contains(current) && held.count > 1 { return nil }
            guard let mode = held.first, mode != current else { return nil }
            phase = .open(mode)
            return .switchMode(mode)
        }
    }

    public mutating func dragEnded() -> Action? {
        defer { phase = .idle }
        if case .open = phase { return .close }
        return nil
    }
}

extension TriggerMachine {
    /// Ayarlardaki tetik tuşları; "none" o halkayı kapatır.
    public static func bindingsFromPreferences() -> [RingMode: TriggerModifiers] {
        var result: [RingMode: TriggerModifiers] = [:]
        for mode in RingMode.allCases {
            switch Preferences.modifier(for: mode) {
            case "shift": result[mode] = .shift
            case "option": result[mode] = .option
            case "control": result[mode] = .control
            default: break
            }
        }
        return result
    }
}
