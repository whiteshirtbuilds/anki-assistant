import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake only while the learning assistant is actively in use.
/// This is released automatically as soon as a live session, recording, response
/// generation and playback have all ended.
final class DisplayWakeLock {
    private var assertionID: IOPMAssertionID = 0

    func setActive(_ active: Bool) {
        if active {
            guard assertionID == 0 else { return }
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Anki-Lernassistent: aktive Lernsitzung" as CFString,
                &assertionID
            )
            if result != kIOReturnSuccess {
                assertionID = 0
            }
        } else if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    deinit {
        setActive(false)
    }
}
