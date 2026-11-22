import SwiftUI

/// Вкладка «Обои»: выбрать видео, включить, решить про батарею. Строки такие
/// же, как в настройках, чтобы вкладка не выглядела чужой.
struct WallpaperPane: View {
    @ObservedObject var wallpaper: WallpaperStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 1) {
                toggleRow(
                    symbol: "play.rectangle",
                    title: localized("Live Wallpaper"),
                    isOn: Binding(get: { wallpaper.isEnabled }, set: { wallpaper.setEnabled($0) }),
                    disabled: wallpaper.videoPath == nil
                )
                videoRow
                toggleRow(
                    symbol: "battery.50percent",
                    title: localized("Pause on Battery"),
                    isOn: Binding(get: { wallpaper.pauseOnBattery }, set: { wallpaper.setPauseOnBattery($0) })
                )
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))

            status
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Строки

    private var videoRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)
            Button(action: wallpaper.chooseVideo) {
                Text(wallpaper.videoPath == nil ? localized("Choose Video…") : localized("Change Video…"))
                    .font(.panelBody)
                    .foregroundStyle(Theme.primary)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if let name = wallpaper.videoName {
                Text(name)
                    .font(.panelCaption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
                Button(action: wallpaper.removeVideo) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localized("Remove Video"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)
            Text(title)
                .font(.panelBody)
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(NotchToggleStyle())
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .opacity(disabled ? 0.4 : 1)
    }

    // MARK: - Состояние

    /// Одна строка о том, что происходит. Ошибка важнее статуса.
    @ViewBuilder
    private var status: some View {
        if let problem = wallpaper.problem {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                Text(problem)
                    .font(.panelCaption)
                    .foregroundStyle(Theme.secondary)
            }
        } else if wallpaper.videoPath == nil {
            Text(localized("No video chosen"))
                .font(.panelCaption)
                .foregroundStyle(Theme.tertiary)
        } else if wallpaper.isEnabled {
            Text(wallpaper.isPlaying ? localized("Playing") : localized("Paused"))
                .font(.panelCaption)
                .foregroundStyle(Theme.tertiary)
        }
    }
}
