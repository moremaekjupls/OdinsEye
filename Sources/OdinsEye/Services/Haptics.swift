import AppKit

/// Лёгкий отклик тачпада. Работает, только пока палец на тачпаде; от мыши
/// ничего не происходит, и это нормально.
@MainActor
enum Haptics {
    static func tick() {
        guard ConfigStore.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
