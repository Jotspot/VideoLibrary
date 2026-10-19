import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(MusicSettings.enabledKey) private var musicEnabled = false
    @AppStorage(MusicSettings.librariesKey) private var musicLibraryIDs = ""
    @AppStorage(MusicSettings.scopeKey) private var musicScope = "library"

    private var filters: [SidebarFilter] {
        SidebarFilter.allCases.filter {
            $0 != .music || MusicSettings.isEnabled(for: store.selectedLibraryID, enabled: musicEnabled, libraryIDs: musicLibraryIDs, scope: musicScope)
        }
    }

    var body: some View {
        List(selection: Bindable(store).selectedFilter) {
            Section("Library") {
                ForEach(filters) { filter in
                    Label(filter.label, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }

            Section("Libraries") {
                ForEach(store.sortedLibraries) { library in
                    libraryRow(library)
                }

                Button {
                    store.chooseLibraryFolder()
                } label: {
                    Label("Add Library Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }

            if !store.uploaders.isEmpty {
                Section("Uploaders") {
                    if store.selectedUploader != nil {
                        Button {
                            store.selectUploader(nil)
                        } label: {
                            Label("All Uploaders", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(store.uploaders, id: \.self) { uploader in
                        Button {
                            store.selectUploader(uploader)
                        } label: {
                            HStack {
                                Text(uploader)
                                    .lineLimit(1)
                                Spacer()
                                if store.selectedUploader == uploader {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("VideoLibrary")
    }

    private func libraryRow(_ library: LibraryLocation) -> some View {
        Button {
            store.selectLibrary(library.id)
        } label: {
            libraryRowContent(library)
        }
        .buttonStyle(.plain)
        .help(library.path)
        .contextMenu {
            libraryContextMenu(library)
        }
    }

    private func libraryRowContent(_ library: LibraryLocation) -> some View {
        HStack {
            Label(library.name, systemImage: store.librarySystemImage(for: library))
                .foregroundStyle(library.isAvailable ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            if !library.isAvailable {
                Text(store.libraryStatusText(for: library))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if library.id == store.selectedLibraryID {
                Image(systemName: "checkmark")
            }
        }
    }

    @ViewBuilder
    private func libraryContextMenu(_ library: LibraryLocation) -> some View {
        Button("Rename...") {
            store.promptRenameLibrary(library)
        }

        Button("Remove from Sidebar", role: .destructive) {
            store.confirmRemoveLibrary(library)
        }
        .disabled(store.libraries.count <= 1)
    }
}
