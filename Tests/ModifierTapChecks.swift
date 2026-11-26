import AppKit

extension RegressionChecks {
    @MainActor static func checkModifierTaps() {
        let selection: Set<ActivationModifier> = [.option, .control]
        func tap(_ detector: inout ModifierDoubleTap, _ flag: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
            let pressed = detector.handle(flags: flag, selected: selection, at: time)
            let released = detector.handle(flags: [], selected: selection, at: time + 0.02)
            return pressed || released
        }

        var detector = ModifierDoubleTap()
        let first = tap(&detector, .option, at: 1)
        let second = tap(&detector, .option, at: 1.1)
        let third = tap(&detector, .option, at: 1.2)
        record("Same modifier triggers only on its second clean tap", !first && second && !third)

        detector.reset()
        _ = tap(&detector, .option, at: 2)
        let different = tap(&detector, .control, at: 2.1)
        let repeated = tap(&detector, .control, at: 2.2)
        record("Different modifiers do not combine into a double tap", !different)
        record("A B B sequence triggers on the second B", repeated)

        detector.reset()
        _ = tap(&detector, .option, at: 3)
        let expired = tap(&detector, .option, at: 3.5)
        let afterExpired = tap(&detector, .option, at: 3.6)
        record("Expired tap starts a new pair", !expired && afterExpired)

        detector.reset()
        _ = tap(&detector, .option, at: 4)
        detector.keyDown()
        record("Ordinary key between taps breaks the pair", !tap(&detector, .option, at: 4.1))

        detector.reset()
        _ = detector.handle(flags: .option, selected: selection, at: 5)
        detector.keyDown()
        let dirtyRelease = detector.handle(flags: [], selected: selection, at: 5.02)
        let afterDirty = tap(&detector, .option, at: 5.1)
        record("Ordinary key held with modifier invalidates that tap", !dirtyRelease && !afterDirty)

        detector.reset()
        _ = tap(&detector, .option, at: 6)
        _ = detector.handle(flags: .option, selected: selection, at: 6.1)
        _ = detector.handle(flags: [.option, .control], selected: selection, at: 6.12)
        _ = detector.handle(flags: .option, selected: selection, at: 6.14)
        let comboRelease = detector.handle(flags: [], selected: selection, at: 6.16)
        let afterCombo = tap(&detector, .option, at: 6.2)
        record("Modifier chord invalidates the tap and preceding candidate", !comboRelease && !afterCombo)

        detector.reset()
        _ = tap(&detector, .option, at: 7)
        _ = detector.handle(flags: .shift, selected: selection, at: 7.1)
        _ = detector.handle(flags: [], selected: selection, at: 7.12)
        record("Unselected modifier breaks the pair", !tap(&detector, .option, at: 7.2))

        detector.reset()
        _ = tap(&detector, .option, at: 8)
        _ = detector.handle(flags: .option, selected: selection, at: 8.1)
        detector.reset()
        let releasedAfterReset = detector.handle(flags: [], selected: selection, at: 8.12)
        let firstAfterReset = tap(&detector, .option, at: 8.2)
        record("Reset clears both held modifier and preceding tap", !releasedAfterReset && !firstAfterReset)

        detector.reset()
        _ = detector.handle(flags: [.option, .capsLock], selected: selection, at: 9)
        _ = detector.handle(flags: .capsLock, selected: selection, at: 9.02)
        _ = detector.handle(flags: [.option, .capsLock], selected: selection, at: 9.1)
        record("Caps Lock does not interfere with modifier double taps",
               detector.handle(flags: .capsLock, selected: selection, at: 9.12))

        detector.reset()
        var mouseOnlyTriggered = false
        for (offset, flags) in [NSEvent.ModifierFlags.option, [], .option, []].enumerated() {
            mouseOnlyTriggered = detector.handle(flags: flags, selected: [.rightClick], at: 10 + Double(offset) * 0.05) || mouseOnlyTriggered
        }
        record("Mouse-only mode ignores modifier taps", !mouseOnlyTriggered)
    }
}
