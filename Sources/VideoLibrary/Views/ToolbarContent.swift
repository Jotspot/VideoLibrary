import SwiftUI
import AppKit

struct AppToolbarContent: ToolbarContent {
    @Binding var showDownloadPanel: Bool
    @Binding var showAddSheet: Bool
    @Binding var pendingAddURL: String
    @Binding var showSharingPanel: Bool
    let sharingServer: LocalSharingServer
    /// In the Music tab, + adds a music folder instead of a video.
    var addMusic: (() -> Void)? = nil
    @Environment(LibraryStore.self) private var store

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text("VideoLibrary")
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")

            Button {
                showSharingPanel.toggle()
            } label: {
                Label(
                    sharingServer.isRunning ? "Sharing On" : "Local Sharing",
                    systemImage: sharingServer.isRunning ? "network.badge.shield.half.filled" : "network"
                )
            }
            .popover(isPresented: $showSharingPanel, arrowEdge: .bottom) {
                LocalSharingPanelView(sharingServer: sharingServer)
                    .environment(store)
            }

            Button {
                withAnimation(.spring(.snappy)) {
                    showDownloadPanel.toggle()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Label(
                        "Downloads",
                        systemImage: store.activeTasks.isEmpty
                            ? "arrow.down.circle"
                            : "arrow.down.circle.fill"
                    )

                    if !store.activeTasks.isEmpty {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -3)
                    }
                }
            }

            if let addMusic {
                Button("Add Music Folder", systemImage: "plus.circle.fill", action: addMusic)
                    .buttonStyle(.borderedProminent)
                    .help("Add a folder of music")
            } else {
                Button("Add Video", systemImage: "plus.circle.fill") {
                    pendingAddURL = ""
                    showAddSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
