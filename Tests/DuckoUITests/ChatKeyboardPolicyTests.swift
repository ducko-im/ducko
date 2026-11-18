import Testing
@testable import DuckoUI

struct ChatKeyboardPolicyTests {
    typealias Field = ChatKeyboardPolicy.Field
    typealias Holder = ChatKeyboardPolicy.Holder

    private static func action(holder: Holder, dueField: Field?) -> ChatKeyboardPolicy.Action {
        ChatKeyboardPolicy.action(isKey: true, hasSheet: false, isOpeningQuietly: false, holder: holder, dueField: dueField)
    }

    @Test(arguments: [nil, Field.message, .search])
    func `coming back to the window hands back what had the keyboard`(dueField: Field?) {
        let action = Self.action(holder: .window, dueField: dueField)

        #expect(action == (dueField.map { .focus($0) } ?? .restore))
    }

    @Test func `what still has the keyboard keeps it`() {
        #expect(Self.action(holder: .view, dueField: nil) == .leave)
    }

    /// Such as the find bar's field in a tab picked with its find bar open, while the message field or the transcript
    /// has the keyboard.
    @Test(arguments: [Field.message, .search])
    func `the due field takes the keyboard from whatever has it`(dueField: Field) {
        #expect(Self.action(holder: .view, dueField: dueField) == .focus(dueField))
    }

    @Test(arguments: [true, false])
    func `the find bar's field is the one due while the bar is open`(isSearching: Bool) {
        #expect(Field(isSearching: isSearching) == (isSearching ? .search : .message))
    }

    /// Such as the find bar's field, still open in the tab picked, or given the keyboard by the user.
    @Test(arguments: [nil, Field.message, .search])
    func `another field the user types in keeps the keyboard`(dueField: Field?) {
        #expect(Self.action(holder: .otherTextInput, dueField: dueField) == .keepTextInput)
    }

    @Test(arguments: [
        (isKey: false, hasSheet: false, isOpeningQuietly: false),
        (isKey: true, hasSheet: true, isOpeningQuietly: false),
        (isKey: true, hasSheet: false, isOpeningQuietly: true)
    ])
    func `the keyboard is left alone without the window, under a sheet, or while opening quietly`(
        isKey: Bool, hasSheet: Bool, isOpeningQuietly: Bool
    ) {
        for holder in [Holder.window, .otherTextInput, .view] {
            for dueField in [nil, Field.message, .search] {
                let action = ChatKeyboardPolicy.action(
                    isKey: isKey, hasSheet: hasSheet, isOpeningQuietly: isOpeningQuietly, holder: holder, dueField: dueField
                )
                #expect(action == .leave)
            }
        }
    }
}
