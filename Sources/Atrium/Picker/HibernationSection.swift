import SwiftUI

/// The hibernation switch shown in every app's Edit window.
struct HibernationSection: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Hibernate when unused", isOn: $isOn)
                .toggleStyle(.switch)
            Text("After 15 minutes without use, Atrium quits this app to free up memory. Click it again to start it back up. A hibernating app can't send notifications while it's off. Off by default.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
