import XCTest
@testable import SpeakPaste

final class MacPasteVerificationTests: XCTestCase {
    func testAcceptsOneExactInsertionAtAnyPosition() {
        XCTAssertTrue(MacPasteVerification.isExactInsertion("hello ", before: "world", after: "hello world"))
        XCTAssertTrue(MacPasteVerification.isExactInsertion("brave ", before: "hello world", after: "hello brave world"))
        XCTAssertTrue(MacPasteVerification.isExactInsertion("!", before: "hello", after: "hello!"))
    }

    func testAcceptsUnicodeInsertionByUTF16Identity() {
        XCTAssertTrue(
            MacPasteVerification.isExactInsertion(
                "👩🏽‍💻 ",
                before: "ships",
                after: "👩🏽‍💻 ships"
            )
        )
    }

    func testRejectsOpaqueDestinationWithoutReadableBaseline() {
        XCTAssertFalse(MacPasteVerification.isExactInsertion("hello", before: nil, after: "hello"))
        XCTAssertFalse(MacPasteVerification.isExactInsertion("hello", before: "draft", after: nil))
    }

    func testRejectsExistingSubstringPlusUnrelatedAsyncEdit() {
        XCTAssertFalse(
            MacPasteVerification.isExactInsertion(
                "already here",
                before: "already here draft",
                after: "already here Draft"
            )
        )
    }

    func testRejectsInsertionMixedWithAutocorrection() {
        XCTAssertFalse(
            MacPasteVerification.isExactInsertion(
                "new text",
                before: "teh draft",
                after: "the new text draft"
            )
        )
    }

    func testRejectsNoChangeAndEmptyInsertion() {
        XCTAssertFalse(MacPasteVerification.isExactInsertion("hello", before: "hello", after: "hello"))
        XCTAssertFalse(MacPasteVerification.isExactInsertion("", before: "draft", after: "draft"))
    }
}
