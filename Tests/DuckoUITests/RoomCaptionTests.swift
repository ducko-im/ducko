import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

struct RoomCaptionTests {
    @Test
    func `subject wins over participant count`() {
        let caption = RoomCaption.resolve(roomSubject: "Standup", participantCount: 5, isCompact: false)
        #expect(caption == .subject("Standup"))
        #expect(caption.hasSecondLine)
    }

    @Test
    func `empty subject falls through to participant count`() {
        #expect(RoomCaption.resolve(roomSubject: "", participantCount: 3, isCompact: false) == .participants(3))
        #expect(RoomCaption.resolve(roomSubject: nil, participantCount: 3, isCompact: false) == .participants(3))
    }

    @Test
    func `no caption when subject empty and no participants`() {
        let caption = RoomCaption.resolve(roomSubject: nil, participantCount: 0, isCompact: false)
        #expect(caption == .none)
        #expect(!caption.hasSecondLine)
    }

    @Test
    func `compact rows show no caption`() {
        let caption = RoomCaption.resolve(roomSubject: "Standup", participantCount: 5, isCompact: true)
        #expect(caption == .none)
        #expect(!caption.hasSecondLine)
    }
}
