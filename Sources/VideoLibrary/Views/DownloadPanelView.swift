import SwiftUI

struct DownloadPanelView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .padding(.horizontal, 12)

            if store.activeTasks.isEmpty {
                Text("No active downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.activeTasks) { task in
                            DownloadRowView(task: task)
                            if task.id != store.activeTasks.last?.id {
                                Divider()
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("Downloads")
                .font(.headline)
            Spacer()
            if !store.activeTasks.isEmpty {
                Text("\(store.activeTasks.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: .capsule)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct DownloadRowView: View {
    @Environment(LibraryStore.self) private var store
    let task: DownloadTask

    var body: some View {
        if case .failed(let failure) = task.phase {
            DownloadFailureView(task: task, failure: failure)
        } else {
            progressBody
        }
    }

    private var progressBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if task.isPlaylist, task.completedVideoCount > 0 {
                Text("\(task.completedVideoCount) videos indexed")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if task.hasDeterminateProgress {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
            }

            HStack {
                Text(task.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(task.percentageLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if task.speed > 0 {
                    Text(formatSpeed(task.speed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if task.canCancel {
                    Button {
                        store.cancelDownload(task)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel Download")
                }
            }

            if task.hasDeterminateProgress {
                Text("\(formatBytes(task.downloadedBytes)) of \(formatBytes(task.totalBytes))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_000_000)
        } else if bytesPerSec >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSec / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSec)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A failed download, explained: what went wrong, what to do, and buttons
/// for the fix. Raw yt-dlp output is one click away under "Details".
private struct DownloadFailureView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let task: DownloadTask
    let failure: DownloadFailure

    @State private var showDetails = false
    @State private var tools = ToolsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title)
                        .font(.subheadline.weight(.semibold))
                    if task.videoItem != nil {
                        Text(task.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    store.activeTasks.removeAll { $0.id == task.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            Text(failure.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                fixButton
                if failure.canRetry, let retry = task.retry {
                    Button("Retry", systemImage: "arrow.clockwise", action: retry)
                        .controlSize(.small)
                }
                Spacer()
                if !failure.details.isEmpty {
                    Button(showDetails ? "Hide Details" : "Details") { showDetails.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if tools.isUpdating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updating download tools…").font(.caption).foregroundStyle(.secondary)
                }
            } else if case .success = tools.lastResult, failure.fix == .updateTools || failure.fix == .installTools {
                Text("Tools updated. Click Retry.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if showDetails {
                ScrollView {
                    Text(failure.details)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(6)
                .background(.black.opacity(0.15), in: .rect(cornerRadius: 6))

                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failure.details, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var fixButton: some View {
        switch failure.fix {
        case .updateTools:
            Button("Update Tools", systemImage: "arrow.triangle.2.circlepath") {
                Task { await tools.updateAll() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(tools.isUpdating)
        case .installTools:
            Button("Install Tools", systemImage: "arrow.down.app") {
                openSettings(tab: .tools)
                Task { await tools.updateAll() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(tools.isUpdating)
        case .chooseBrowserCookies:
            Button("Choose Browser…", systemImage: "person.crop.circle.badge.checkmark") {
                openSettings(tab: .downloads)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .pickDifferentQuality:
            Button("Change Quality…", systemImage: "slider.horizontal.3") {
                openSettings(tab: .downloads)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .reconnectLibrary:
            Button("Library Settings…", systemImage: "externaldrive") {
                openSettings(tab: .general)
            }
            .controlSize(.small)
        case .none:
            EmptyView()
        }
    }
}
