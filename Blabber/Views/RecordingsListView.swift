import SwiftUI

struct RecordingsListView: View {
    @State private var recordings: [Recording] = []
    @State private var selectedRecording: Recording?
    @State private var downloadingIDs: Set<UUID> = []
    @State private var pendingPlayRecording: Recording?

    private let storage = StorageService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                MeshBackground()

                if recordings.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(recordings) { recording in
                            RecordingRow(recording: recording,
                                         isProcessing: recording.isProcessing,
                                         isDownloading: downloadingIDs.contains(recording.id),
                                         isCloudOnly: !storage.isAvailableLocally(recording))
                                .listRowBackground(Color.white.opacity(0.06))
                                .listRowSeparatorTint(Color.white.opacity(0.08))
                                .onTapGesture {
                                    handleTap(recording)
                                }
                        }
                        .onDelete { indexSet in
                            for i in indexSet { storage.deleteRecording(recordings[i]) }
                            recordings.remove(atOffsets: indexSet)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { recordings = storage.loadRecordings() }
            .onReceive(NotificationCenter.default.publisher(for: .recordingsDidChange)) { _ in
                recordings = storage.loadRecordings()
                if let pending = pendingPlayRecording, storage.isAvailableLocally(pending) {
                    pendingPlayRecording = nil
                    downloadingIDs.remove(pending.id)
                    selectedRecording = pending
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .recordingDownloadRequested)) { note in
                if let id = note.object as? UUID {
                    downloadingIDs.insert(id)
                }
            }
            .sheet(item: UIDevice.current.userInterfaceIdiom != .pad ? $selectedRecording : Binding<Recording?>.constant(nil)) { recording in
                PlayerView(recording: recording)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: UIDevice.current.userInterfaceIdiom == .pad ? $selectedRecording : Binding<Recording?>.constant(nil)) { recording in
                PlayerView(recording: recording)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func handleTap(_ recording: Recording) {
        guard !recording.isProcessing else { return }

        if storage.isAvailableLocally(recording) {
            downloadingIDs.remove(recording.id)
            selectedRecording = recording
        } else if !downloadingIDs.contains(recording.id) {
            storage.requestDownload(recording)
            pendingPlayRecording = recording
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 68))
                .foregroundStyle(
                    LinearGradient(colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("No recordings yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            Text("Tap Record and start a conversation")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding()
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 40)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let isProcessing: Bool
    let isDownloading: Bool
    let isCloudOnly: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.blue.opacity(0.5), Color.purple.opacity(0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(durationString)
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            trailingIndicator
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isProcessing {
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .tint(.white.opacity(0.5))
                Text("Processing")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        } else if isDownloading {
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .tint(.white.opacity(0.5))
                Text("Downloading")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        } else if isCloudOnly {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.4))
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    private var durationString: String {
        let mins = Int(recording.duration) / 60
        let secs = Int(recording.duration) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}
