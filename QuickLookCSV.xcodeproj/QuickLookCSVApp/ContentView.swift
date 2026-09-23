import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 48))
            Text("QuickLook CSV")
                .font(.title)
            Text("This app installs the CSV preview and thumbnail extensions. You can quit this window — Quick Look uses the extensions automatically once the app is in /Applications.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Open Extensions Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 280)
    }
}

#Preview {
    ContentView()
}