// SPDX-License-Identifier: GPL-2.0-or-later
import Testing
@testable import RTLSDRKit

/// macOS reports "Failed to create IOUSBHostObject" for several unrelated reasons. The IOKit code says which,
/// and the message must not blame "another program" when the code says something else (for example a sandbox denial).
struct OpenFailureTests {
    @Test func exclusiveAccessBlamesAnotherProgram() {
        let text = RTLSDRError.explainOpenFailure(code: 0xe00002c5, description: "Failed to create IOUSBHostObject.")
        #expect(text.localizedCaseInsensitiveContains("another program"))
        #expect(text.contains("0xe00002c5"))
    }

    @Test func busyBlamesAnotherProgramToo() {
        #expect(RTLSDRError.explainOpenFailure(code: 0xe00002d5, description: "x").localizedCaseInsensitiveContains("another program"))
    }

    @Test(arguments: [0xe00002e2, 0xe00002c1])
    func notPermittedPointsAtTheSandboxEntitlementNotAtAnotherProgram(code: Int) {
        let text = RTLSDRError.explainOpenFailure(code: code, description: "Failed to create IOUSBHostObject.")
        #expect(text.contains("com.apple.security.device.usb"))
        #expect(!text.localizedCaseInsensitiveContains("another program"))
    }

    @Test func noDeviceMeansItWasUnplugged() {
        #expect(RTLSDRError.explainOpenFailure(code: 0xe00002c0, description: "x").localizedCaseInsensitiveContains("unplugged"))
    }

    @Test func anUnknownCodeIsShownRawAndDoesNotGuess() {
        let text = RTLSDRError.explainOpenFailure(code: 0xe00002bc, description: "Failed to create IOUSBHostObject.")
        #expect(text.contains("0xe00002bc") && text.contains("Failed to create IOUSBHostObject"))
        #expect(!text.localizedCaseInsensitiveContains("another program"))
    }

    @Test func aNegativeSignExtendedCodeIsReadAsTheSameCode() {
        // NSError.code holds IOReturn sign-extended; the message must show the familiar unsigned form.
        let text = RTLSDRError.explainOpenFailure(code: Int(Int32(bitPattern: 0xe00002c5)), description: "x")
        #expect(text.contains("0xe00002c5"))
    }

    @Test func theErrorDescriptionAddsNoBlameOfItsOwn() {
        let text = RTLSDRError.openFailed("something specific").errorDescription ?? ""
        #expect(text.contains("something specific"))
        #expect(!text.localizedCaseInsensitiveContains("another program"))
    }
}
