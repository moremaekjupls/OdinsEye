import SwiftUI

struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode

    var body: some View {
        VStack(spacing: 0) {
            if clipboard.items.isEmpty {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    // Lazy: the history has no limit, and only rows in view
                    // are built, so a thousand entries open as fast as ten.
                    LazyVStack(spacing: 3) {
                        ForEach(clipboard.items) { item in
                            ClipRow(item: item, clipboard: clipboard, privacy: privacy)
                        }
                    }
                    .padding(.vertical, 4)
                }
                footer
            }
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            PrivacySwitch(privacy: privacy, section: .clipboard)
            // Pinned entries stay: "Clear" is for the stream, not the keepers.
            Button("Clear") { clipboard.clear() }
                .buttonStyle(.plate)
                .disabled(!clipboard.hasUnpinned)
        }
        .padding(.top, 2)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    @State private var hovering = false
    @State private var justCopied = false

    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : (item.isPinned ? "pin.fill" : item.symbol))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : (item.isPinned ? Theme.secondary : Theme.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
            SpoilerText(
                text: item.preview.replacingOccurrences(of: "\n", with: " "),
                hidden: hidden,
                seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue))
            )
            Spacer(minLength: 6)
            if hovering {
                HStack(spacing: 0) {
                    if privacy.covers(.clipboard) {
                        RevealEye(hidden: hidden) { privacy.toggle(item.id.uuidString) }
                    }
                    RowIconButton(
                        symbol: item.isPinned ? "pin.slash" : "pin",
                        help: item.isPinned ? localized("Unpin") : localized("Pin")
                    ) { clipboard.togglePin(item) }
                    // A pinned entry is deleted only after it is unpinned: one
                    // stray click must not take a keeper.
                    if !item.isPinned {
                        RowIconButton(symbol: "xmark", help: localized("Delete")) { clipboard.remove(item) }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            clipboard.copy(item)
            flash($justCopied)
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }
}
