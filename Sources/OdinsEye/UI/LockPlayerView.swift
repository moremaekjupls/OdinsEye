import os
import SwiftUI

private let tapLog = Logger(subsystem: "com.moremaekjupls.odinseye", category: "lockscreen")

/// Карточка «сейчас играет» для экрана блокировки в стиле системного плеера
/// Apple: обложка слева, название и исполнитель, значок звука справа, ход
/// песни с временем по краям, крупные кнопки. Единственное окно на блокировке,
/// и оно принимает только нажатия на кнопки.
struct LockControlsView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 34, style: .continuous) }

    var body: some View {
        // Позиция читается по таймеру из «живых» часов плеера: у приложения без
        // окон тики самого плеера опаздывают.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let position = media.livePosition()
            VStack(spacing: 10) {
                header(position)
                progress(position)
                buttons
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GlassSurface(shape: shape, tint: 0.3))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
    }

    // MARK: - Верх: обложка, названия, значок

    private func header(_ position: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(media.track?.title ?? "")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                // Исполнитель, а когда у песни есть текст, поверх него строка текста:
                // она занимает то же место, так что карточка не прыгает.
                Text(subtitle(position))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(media.isPlaying ? 0.45 : 0.25))
                .symbolEffect(.variableColor.iterative, isActive: media.isPlaying)
        }
    }

    private func subtitle(_ position: TimeInterval) -> String {
        if let line = lyrics.visible(at: position).current, !line.isEmpty { return line }
        return media.track?.artist ?? ""
    }

    private var artwork: some View {
        ZStack {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: - Ход: время по краям, полоса между ними

    private func progress(_ position: TimeInterval) -> some View {
        let fraction = media.duration > 0 ? min(max(position / media.duration, 0), 1) : 0
        return HStack(spacing: 10) {
            Text(formatTime(position)).frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.62)).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)
            Text("-" + formatTime(max(media.duration - position, 0))).frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - Кнопки

    private var buttons: some View {
        HStack(spacing: 0) {
            // Левая и правая ячейки одной ширины: воспроизведение всегда по центру.
            Color.clear.frame(maxWidth: .infinity)
            HStack(spacing: 40) {
                Button { tapLog.notice("tap: previous"); media.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 26))
                }
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
                Button { tapLog.notice("tap: playpause"); media.togglePlayPause() } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36))
                        .contentTransition(.symbolEffect(.replace.downUp, options: .speed(2)))
                }
                Button { tapLog.notice("tap: next"); media.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 26))
                }
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
            }
            ZStack(alignment: .trailing) {
                Color.clear
                // Сердце есть только у Apple Music; без него ячейка пуста.
                if media.canFavorite {
                    Button { tapLog.notice("tap: heart"); media.toggleFavorite() } label: {
                        Image(systemName: media.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 20))
                            .foregroundStyle(media.isFavorite ? Color.pink : Color.white.opacity(0.55))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LockButtonStyle())
        .frame(height: 46)
    }
}

/// Нажатие отвечает сразу, на касании: лёгкое сжатие и затемнение. Подсветки
/// по наведению нет: на блокировке курсор ничего не обещает.
private struct LockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 40, minHeight: 40)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
