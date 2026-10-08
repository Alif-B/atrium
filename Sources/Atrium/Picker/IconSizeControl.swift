import SwiftUI

/// Preview of a chosen icon inside a faint frame that shows its allotted space, with a Size slider under it.
struct IconSizeControl: View {
    let preview: NSImage?
    @Binding var scale: Double

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 96, height: 96)
                if let preview {
                    Image(nsImage: preview).resizable().interpolation(.high).frame(width: 96, height: 96)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $scale, in: SiteIconFetcher.scaleRange)
                    .frame(width: 130)
                    .accessibilityLabel("Icon size")
                Image(systemName: "photo").font(.system(size: 16)).foregroundStyle(.secondary)
            }
        }
    }
}
