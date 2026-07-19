

import SwiftUI
import VLCKit

/// VLC fallback for payloads the remux/AVPlayer path can't handle (DTS audio,
/// exotic containers…). Same VLCKit the iOS/tvOS apps bundle — the macOS
/// slice ships in the same xcframework.
struct MacVLCPlayerView: View {
    let url: URL
    @StateObject private var controller = MacVLCController()

    var body: some View {
        ZStack(alignment: .bottom) {
            MacVLCVideoRepresentable(controller: controller)
                .background(Color.black)

            // Minimal transport bar.
            HStack(spacing: 14) {
                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Text(controller.timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(value: Binding(get: { controller.position },
                                      set: { controller.seek(to: $0) }))

                Text(controller.remainingLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
        .onAppear { controller.play(url) }
        .onDisappear { controller.stop() }
    }
}

@MainActor
final class MacVLCController: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var timeLabel = "--:--"
    @Published var remainingLabel = "--:--"

    let player = VLCMediaPlayer()
    private var timer: Timer?

    func play(_ url: URL) {
        player.media = VLCMedia(url: url)
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        // Don't fight the user mid-drag; VLC position is 0…1.
        position = player.position
        timeLabel = player.time.stringValue
        remainingLabel = player.remainingTime?.stringValue ?? "--:--"
        isPlaying = player.isPlaying
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
    }

    func seek(to newPosition: Double) {
        player.position = newPosition
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player.stop()
    }
}

struct MacVLCVideoRepresentable: NSViewRepresentable {
    let controller: MacVLCController

    func makeNSView(context: Context) -> VLCVideoView {
        let view = VLCVideoView()
        controller.player.drawable = view
        return view
    }

    func updateNSView(_ view: VLCVideoView, context: Context) {}
}
