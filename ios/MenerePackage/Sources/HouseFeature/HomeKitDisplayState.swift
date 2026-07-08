import HomeKitClient

// W2a — surfacing the HomeKit fault/motion states the model already carries but the House UI collapsed
// away. `HKAccessory.lockIsLocked` folds jammed(2)/unknown(3) into "unlocked", and the garage rows keep
// only a Bool `isOpen` (losing opening/closing/stopped). These HouseFeature-local reads keep the full
// `currentLockState` / `currentDoorState` fidelity without changing the HomeKitClient value types — the
// raw characteristic ints (documented on `HKCharacteristicType`) are already in the snapshot.

/// A door lock's display state, read straight from `currentLockState` (0 unsecured · 1 secured · 2
/// jammed · 3 unknown). `jammed` covers BOTH a physically stuck bolt (2) and an indeterminate reading
/// (3) — either way the lock isn't confidently locked or unlocked, so the row must say so.
enum LockDisplayState: Equatable {
    case locked
    case unlocked
    case jammed
}

/// A garage door's display state, read straight from `currentDoorState` (0 open · 1 closed · 2 opening ·
/// 3 closing · 4 stopped). `stopped` is HomeKit's "the door halted mid-travel" — a real, surfaced state
/// rather than the reducer's blind 20s settle pretending the door reached a resting position.
enum GarageDoorDisplayState: Equatable {
    case open
    case closed
    case opening
    case closing
    case stopped
}

extension HKAccessory {
    /// The lock's full display state from `currentLockState`, nil when the accessory has no lock service
    /// / no reading. `lockIsLocked` (which folds jammed→unlocked) stays for the plain locked/unlocked
    /// callers; this is the fidelity path the row uses.
    var lockDisplayState: LockDisplayState? {
        guard let raw = service(.lockMechanism)?.characteristic(.currentLockState)?.value?.intValue
        else { return nil }
        switch raw {
        case 1: return .locked
        case 0: return .unlocked
        default: return .jammed   // 2 jammed · 3 unknown — both are "can't trust it"
        }
    }

    /// The garage door's full display state from `currentDoorState`, nil when the accessory has no
    /// garage-door service / no reading.
    var garageDoorDisplayState: GarageDoorDisplayState? {
        guard let raw = service(.garageDoorOpener)?.characteristic(.currentDoorState)?.value?.intValue
        else { return nil }
        switch raw {
        case 0: return .open
        case 1: return .closed
        case 2: return .opening
        case 3: return .closing
        case 4: return .stopped
        default: return nil
        }
    }
}
