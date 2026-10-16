import SwiftUI

struct RepositoryLink: View {
    private static let destination = URL(string: "https://github.com/LocalLens-Project/Ripple")!

    var body: some View {
        Link(Self.destination.absoluteString, destination: Self.destination)
            .font(.system(size: 11))
            .foregroundStyle(Color(red: 0.55, green: 0.76, blue: 1))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .help(Self.destination.absoluteString)
            .accessibilityLabel(L10n.text("GitHub 开源仓库", "GitHub repository"))
            .accessibilityValue(Self.destination.absoluteString)
    }
}
