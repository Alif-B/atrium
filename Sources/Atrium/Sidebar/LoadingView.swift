import SwiftUI

/// What Atrium's workspace shows while it opens your apps at launch: calm, centred, no spinner flashing past.
struct LoadingView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Opening your apps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
