import DragConvertCore
import Testing
@testable import DragConvertDrag

struct TriggerMachineTests {
    @Test func modifiersOutsideADragDoNothing() {
        var machine = TriggerMachine()
        #expect(machine.modifiersChanged(.shift) == nil)
        #expect(machine.phase == .idle)
    }

    @Test func shiftDuringDragOpensConvert() {
        var machine = TriggerMachine()
        #expect(machine.dragBegan(modifiers: []) == nil)
        #expect(machine.modifiersChanged(.shift) == .open(.convert))
        #expect(machine.phase == .open(.convert))
    }

    @Test func modifierHeldBeforeDragOpensImmediately() {
        var machine = TriggerMachine()
        #expect(machine.dragBegan(modifiers: .option) == .open(.tools))
    }

    @Test func releasingClosesButDragContinues() {
        var machine = TriggerMachine()
        _ = machine.dragBegan(modifiers: .shift)
        #expect(machine.modifiersChanged([]) == .close)
        #expect(machine.phase == .dragging)
        #expect(machine.modifiersChanged(.control) == .open(.actions))
    }

    @Test func overlappingKeysKeepCurrentModeThenSwitch() {
        var machine = TriggerMachine()
        _ = machine.dragBegan(modifiers: .shift)
        #expect(machine.modifiersChanged([.shift, .option]) == nil)
        #expect(machine.modifiersChanged(.option) == .switchMode(.tools))
    }

    @Test func multipleKeysAtOpenUsePrecedence() {
        var machine = TriggerMachine()
        _ = machine.dragBegan(modifiers: [])
        #expect(machine.modifiersChanged([.control, .option]) == .open(.tools))
    }

    @Test func dragEndClosesOpenRing() {
        var machine = TriggerMachine()
        _ = machine.dragBegan(modifiers: .shift)
        #expect(machine.dragEnded() == .close)
        #expect(machine.phase == .idle)
    }

    @Test func dragEndWithoutRingIsQuiet() {
        var machine = TriggerMachine()
        _ = machine.dragBegan(modifiers: [])
        #expect(machine.dragEnded() == nil)
    }

    @Test func customBindings() {
        var machine = TriggerMachine(bindings: [.convert: .option, .tools: .shift])
        _ = machine.dragBegan(modifiers: [])
        #expect(machine.modifiersChanged(.option) == .open(.convert))
        // ⌃ hiçbir moda bağlı değil: tetik tuşu yok sayılır, halka kapanır.
        #expect(machine.modifiersChanged(.control) == .close)
    }
}
