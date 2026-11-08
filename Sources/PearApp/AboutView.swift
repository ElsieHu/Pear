import SwiftUI
import AppKit

/// Pear's own About window.
///
/// macOS' standard About panel (`orderFrontStandardAboutPanel`) can only show
/// the bundle name, a version string and a plain-text copyright line. It has
/// no place for an author row or a clickable link, and it renders the version
/// as "1.1.0 (2)" by appending `CFBundleVersion` to the marketing version.
/// A small SwiftUI window keeps that text under our control and gives the
/// user a direct route to the GitHub Releases page for updates.
@MainActor
struct AboutView: View {
    /// Single source of truth: build.sh writes CFBundleShortVersionString.
    /// The fallback matches that value so a bare `swift run` still reads 1.2.0.
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    private let repositoryURL = "https://github.com/ElsieHu/Pear"
    private let releasesURL = "https://github.com/ElsieHu/Pear/releases/latest"

    var body: some View {
        VStack(spacing: 16) {
            icon

            Text("Pear")
                .font(.system(size: 26, weight: .semibold))

            // The version is written as a plain three-part number. The old
            // standard panel appended the build number in parentheses.
            Text("版本 \(version)")
                .font(.body)
                .foregroundStyle(.secondary)

            Text("🍐，Apple Music的桌面歌词伙伴")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .padding(.vertical, 2)

            VStack(spacing: 10) {
                infoRow("作者") {
                    Text("Elsie Hu").textSelection(.enabled)
                }
                infoRow("GitHub") {
                    Link("github.com/ElsieHu/Pear", destination: URL(string: repositoryURL)!)
                        .textSelection(.enabled)
                }
                infoRow("检查更新") {
                    Link("查看最新版本", destination: URL(string: releasesURL)!)
                }
            }

            Text("© 2026 Elsie Hu")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var icon: some View {
        Group {
            if let image = NSApp.applicationIconImage {
                Image(nsImage: image)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 72, height: 72)
    }

    private func infoRow<Content: View>(_ label: String,
                                        @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body)
    }
}
