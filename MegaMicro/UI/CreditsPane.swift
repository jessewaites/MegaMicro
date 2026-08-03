import SwiftUI

/// About/credits. The copy below is meant to be edited directly — it's just
/// text in this file.
struct CreditsPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MegaMicro")
                        .font(.largeTitle.bold())
                    Text("Run your fleet of AI agents from a keyboard.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Built in Boston by Jesse Waites")
                        .font(.headline)
                    Text("""
                    MegaMicro turns the Work Louder Codex Micro into a physical control \
                    surface for AI coding agents — approve plans, switch models, and summon \
                    dictation with real keys, while every agent glows its status on its own \
                    key. Built for Conductor, Claude Code, Codex, and whatever ships next.
                    """)
                    Link("JesseWaites.com", destination: URL(string: "https://JesseWaites.com")!)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("The Designed with AI Podcast", systemImage: "mic.fill")
                        .font(.headline)
                    Text("""
                    I host a podcast about building real things with AI — tools like this \
                    one, the people making them, and how software gets made now. If \
                    MegaMicro is your kind of thing, the show will be too.
                    """)
                    Link("DesignedWith.AI", destination: URL(string: "https://DesignedWith.AI")!)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Thanks")
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text("Jon Borgwing —")
                        Link("@Jborgwing", destination: URL(string: "https://x.com/Jborgwing")!)
                    }
                    .font(.callout)
                    HStack(spacing: 4) {
                        Text("Scott Chacon —")
                        Link("@chacon", destination: URL(string: "https://x.com/chacon")!)
                    }
                    .font(.callout)
                    Text("Scott worked out that the Creator Micro 2's per-key lighting only responds once the keys are bound to the firmware's agent keycodes, and shared it. Without that, the colors on this keyboard would still be one shade for the whole board.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                Text("MegaMicro \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · © 2026 Jesse Waites")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}
