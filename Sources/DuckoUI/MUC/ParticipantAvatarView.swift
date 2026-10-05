import SwiftUI

struct ParticipantAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme
    let nickname: String
    let size: CGFloat

    init(nickname: String, size: CGFloat = 28) {
        self.nickname = nickname
        self.size = size
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.forNickname(nickname, colorScheme: colorScheme), in: .circle)
    }

    private var initials: String {
        let chars = nickname.prefix(2).uppercased()
        return String(chars)
    }
}
