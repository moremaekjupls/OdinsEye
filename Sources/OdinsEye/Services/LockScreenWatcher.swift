import AppKit

/// Знает, заблокирован ли экран. macOS сообщает об этом распределёнными
/// уведомлениями; публичного API на это нет, но эти два имени годами не
/// менялись.
///
/// Подписка обязательно с `.deliverImmediately`: версия с блоком такой настройки
/// не имеет, и фоновому приложению система копит уведомления до активации.
@MainActor
final class LockScreenWatcher: NSObject {
    private let onChange: @MainActor (Bool) -> Void
    private var started = false

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !started else { return }
        started = true
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"),
            object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(
            self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    func stop() {
        guard started else { return }
        started = false
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func locked(_ note: Notification) { onChange(true) }
    @objc private func unlocked(_ note: Notification) { onChange(false) }
}
