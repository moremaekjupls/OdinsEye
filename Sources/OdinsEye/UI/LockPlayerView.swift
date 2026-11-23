import os
import SwiftUI

private let tapLog = Logger(subsystem: "com.moremaekjupls.odinseye", category: "lockscreen")

/// Карточка «сейчас играет» для экрана блокировки в стиле системного плеера
/// Apple: обложка слева, название и исполнитель, значок звука справа, ход
/// песни с временем по краям, крупные кнопки. Единственное окно на блокировке,
/// и оно принимает только нажатия на кнопки.
/// Раскрыта ли обложка. Живёт в `LockScreenPlayer`: окно меняет размер вместе с ней.
@MainActor
final class LockCoverState: ObservableObject {
    @Published var expanded = false
}

/// Экран блокировки как у плеера на iPhone: компактная стеклянная таблетка с
/// маленькой обложкой слева. Нажатие на неё выдвигает большую обложку сверху,
/// таблетка при этом уходит вниз; ещё одно нажатие убирает обложку.
/// Единственное окно на блокировке, и оно принимает только нажатия на кнопки.
struct LockControlsView: View {
    @ObservedObject var cover: LockCoverState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject private var config = ConfigStore.shared
    let layout: LockScreenPolicy.Layout

    private var pill: RoundedRectangle { RoundedRectangle(cornerRadius: 28, style: .continuous) }
    private var coverShape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    /// Пружина без отскока: обложка и таблетка движутся одним жестом и могут
    /// быть перехвачены на середине. Без анимации движения: короткое затухание.
    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.9)
    }

    private func toggleCover() {
        guard layout.coverSide > 0 else { return }
        tapLog.notice("tap: cover expanded=\(!cover.expanded, privacy: .public)")
        withAnimation(motion) { cover.expanded.toggle() }
    }

    var body: some View {
        VStack(spacing: LockScreenPolicy.gap) {
            if cover.expanded, layout.coverSide > 0 { bigCover }
            player
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Обложка

    private var bigCover: some View {
        Button(action: toggleCover) { coverImage }
            .buttonStyle(PressScaleStyle(scale: 0.985))
            .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
            .accessibilityLabel(localized("Close cover"))
    }

    private var coverImage: some View {
        artworkImage
            .frame(width: layout.coverSide, height: layout.coverSide)
            .clipShape(coverShape)
            .overlay(coverShape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
    }

    @ViewBuilder private var artworkImage: some View {
        if let image = media.artwork {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.1)
                Image(systemName: "music.note").font(.system(size: 44)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Плеер

    private var player: some View {
        // Позиция читается по таймеру из «живых» часов плеера: у приложения без
        // окон тики самого плеера опаздывают.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let position = media.livePosition()
            VStack(spacing: 8) {
                header(position)
                progress(position)
                buttons
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .frame(height: layout.playerHeight)
            .background(GlassSurface(shape: pill, tint: config.lockGlassTint))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        }
    }

    private func header(_ position: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 0) {
                Text(media.track?.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.1)
                    .lineLimit(1)
                // Исполнитель, а когда у песни есть текст, поверх него строка текста:
                // она занимает то же место, так что таблетка не прыгает.
                Text(subtitle(position))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(media.isPlaying ? 0.5 : 0.25))
                .symbolEffect(.variableColor.iterative, isActive: media.isPlaying)
        }
    }

    private var thumbnail: some View {
        Button(action: toggleCover) {
            artworkImage
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
        .accessibilityLabel(localized("Show full cover"))
    }

    private func subtitle(_ position: TimeInterval) -> String {
        if let line = lyrics.visible(at: position).current, !line.isEmpty { return line }
        return media.track?.artist ?? ""
    }

    // MARK: - Ход: время по краям, полоса между ними

    private func progress(_ position: TimeInterval) -> some View {
        let fraction = media.duration > 0 ? min(max(position / media.duration, 0), 1) : 0
        return HStack(spacing: 10) {
            Text(formatTime(position)).frame(width: 36, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.62)).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            Text("-" + formatTime(max(media.duration - position, 0))).frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - Кнопки

    private var buttons: some View {
        HStack(spacing: 0) {
            // Левая и правая ячейки одной ширины: воспроизведение всегда по центру.
            Color.clear.frame(maxWidth: .infinity)
            HStack(spacing: 34) {
                Button { tapLog.notice("tap: previous"); media.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 21))
                }
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
                Button { tapLog.notice("tap: playpause"); media.togglePlayPause() } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .contentTransition(.symbolEffect(.replace.downUp, options: .speed(2)))
                }
                Button { tapLog.notice("tap: next"); media.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 21))
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
                            .font(.system(size: 17))
                            .foregroundStyle(media.isFavorite ? Color.pink : Color.white.opacity(0.55))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LockButtonStyle())
        .frame(height: 36)
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

/// Сжатие на касании, сразу: отклик не ждёт отпускания.
private struct PressScaleStyle: ButtonStyle {
    let scale: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
