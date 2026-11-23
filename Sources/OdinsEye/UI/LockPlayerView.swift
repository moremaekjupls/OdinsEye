import SwiftUI

/// Карточка «сейчас играет» для экрана блокировки. Показывает и ничего не
/// принимает: окно под ней не ловит мышь.
struct LockPlayerView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore

    var body: some View {
        // Позиция читается по таймеру из «живых» часов плеера: у приложения без
        // окон тики самого плеера опаздывают.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let position = media.livePosition()
            HStack(spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.track?.title ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(media.track?.artist ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    lyricLines(at: position)
                    progress(position)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.45))
            )
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
            )
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var artwork: some View {
        ZStack {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func lyricLines(at position: TimeInterval) -> some View {
        let line = lyrics.visible(at: position)
        VStack(alignment: .leading, spacing: 2) {
            Text(line.current ?? " ")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text(line.next ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
    }

    private func progress(_ position: TimeInterval) -> some View {
        let fraction = media.duration > 0 ? min(max(position / media.duration, 0), 1) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.9)).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}
