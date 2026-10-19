import SwiftUI

struct LocalSharingPanelView: View {
    @Environment(LibraryStore.self) private var store
    let sharingServer: LocalSharingServer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Toggle("Use Reusable Link", isOn: reusableLinkBinding)
                .toggleStyle(.switch)

            Text("Reusable links keep the same access token across sharing sessions. Turn this off when you want a fresh private link each time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if sharingServer.isRunning, let url = sharingServer.displayURL {
                VStack(alignment: .center, spacing: 12) {
                    QRCodeView(text: url)
                        .frame(width: 190, height: 190)

                    Text(url)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity)

                HStack {
                    Button("Copy Link") {
                        sharingServer.copyLink()
                    }

                    if sharingServer.usesReusableToken {
                        Button("Regenerate Token") {
                            sharingServer.regenerateReusableToken(
                                libraries: store.sharingSnapshots(),
                                selectedLibraryID: store.selectedLibraryID
                            )
                        }
                    }

                    Spacer()

                    Button("Stop", role: .destructive) {
                        sharingServer.stop()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else {
                Text("Start sharing to show a QR code and local web link for devices on the same Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Start Local Sharing") {
                    sharingServer.start(
                        libraries: store.sharingSnapshots(),
                        selectedLibraryID: store.selectedLibraryID
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.selectedLibraryIsAvailable)
            }

            if let error = sharingServer.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Label(
                sharingServer.isRunning ? "Local Sharing On" : "Local Sharing",
                systemImage: sharingServer.isRunning ? "network.badge.shield.half.filled" : "network"
            )
            .font(.headline)

            Spacer()

            if sharingServer.isRunning {
                Text("\(store.items.filter { $0.status == .downloaded }.count) videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reusableLinkBinding: Binding<Bool> {
        Binding(
            get: { sharingServer.usesReusableToken },
            set: {
                sharingServer.setUsesReusableToken(
                    $0,
                    libraries: store.sharingSnapshots(),
                    selectedLibraryID: store.selectedLibraryID
                )
            }
        )
    }
}
