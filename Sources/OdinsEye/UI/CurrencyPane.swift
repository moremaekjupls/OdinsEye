import SwiftUI

/// Two editable amounts, source on the left and result on the right — the same
/// shape as the translator, because both are "type on one side, read the
/// other". Either side accepts a figure; the empty one follows.
struct CurrencyPane: View {
    @ObservedObject var currencies: CurrencyStore
    @Binding var wantsKeyboard: Bool

    private enum Field { case source, target, search }
    private enum PickerSide { case source, target }

    @FocusState private var focused: Field?
    @State private var picking: PickerSide?
    @State private var query = ""
    /// Half-turns of the swap arrows — each swap spins them once, so the
    /// press shows what it did.
    @State private var swapTurns = 0.0

    var body: some View {
        Group {
            if let picking {
                picker(for: picking)
            } else {
                converter
            }
        }
        .padding(.top, 2)
        .onAppear {
            currencies.refreshIfNeeded()
            if wantsKeyboard { focused = .source }
        }
        .onChange(of: wantsKeyboard) { _, wants in
            if wants {
                focused = picking == nil ? .source : .search
            } else {
                focused = nil
            }
        }
    }

    // MARK: - Converter

    private var converter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                amountColumn(
                    code: currencies.sourceCode,
                    name: currencies.name(for: currencies.sourceCode),
                    side: .source,
                    text: Binding(
                        get: { currencies.sourceText },
                        set: { currencies.setSourceText($0) }
                    )
                )

                Button {
                    currencies.swap()
                    swapTurns += 1
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(180 * swapTurns))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(Theme.surface)
                        )
                        .contentShape(Circle())
                        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: swapTurns)
                }
                .buttonStyle(.pressable)
                .pointerStyle(.default)
                .padding(.top, 28)
                .help(localized("Swap currencies"))

                amountColumn(
                    code: currencies.targetCode,
                    name: currencies.name(for: currencies.targetCode),
                    side: .target,
                    text: Binding(
                        get: { currencies.targetText },
                        set: { currencies.setTargetText($0) }
                    )
                )
            }

            if let failure = currencies.failure, currencies.rates.isEmpty {
                Text(failure)
                    .font(.panelCaption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func amountColumn(
        code: String,
        name: String,
        side: Field,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                query = ""
                picking = side == .source ? .source : .target
                if wantsKeyboard { focused = .search }
            } label: {
                HStack(spacing: 6) {
                    Text(code.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(name)
                        .font(.panelCaption)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    // The same double chevron as a macOS pop-up button: it
                    // says "a list opens here", not "this drops down".
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.surface)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.pressable)
            .pointerStyle(.default)

            TextField("0", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.primary)
            .tint(Theme.secondary)
            .focused($focused, equals: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
            .onKeyPress(.escape) {
                text.wrappedValue = ""
                return .handled
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Picker

    private func picker(for side: PickerSide) -> some View {
        let selected = side == .source ? currencies.sourceCode : currencies.targetCode
        let matches = currencies.filtered(query: query)

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                TextField(localized("Search currency"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.panelBody)
                    .foregroundStyle(Theme.primary)
                    .tint(Theme.secondary)
                    .focused($focused, equals: .search)
                    .onKeyPress(.escape) {
                        if query.isEmpty {
                            closePicker()
                        } else {
                            query = ""
                        }
                        return .handled
                    }
                if !query.isEmpty {
                    RowIconButton(symbol: "xmark.circle.fill", tint: Theme.tertiary) { query = "" }
                }
                Button(localized("Done")) { closePicker() }
                    .buttonStyle(.plate)
            }
            .padding(.leading, 9)
            .padding(.trailing, 3)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surface)
            )

            if let failure = currencies.failure, currencies.currencies.isEmpty {
                Text(failure)
                    .font(.panelBody)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else if matches.isEmpty {
                Text(localized("No currencies match"))
                    .font(.panelBody)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { currency in
                            CurrencyRow(currency: currency, selected: currency.code == selected) {
                                choose(currency.code, for: side)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { if wantsKeyboard { focused = .search } }
    }

    private func choose(_ code: String, for side: PickerSide) {
        switch side {
        case .source:
            if code == currencies.targetCode {
                currencies.swap()
            } else {
                currencies.sourceCode = code
            }
        case .target:
            if code == currencies.sourceCode {
                currencies.swap()
            } else {
                currencies.targetCode = code
            }
        }
        closePicker()
    }

    private func closePicker() {
        picking = nil
        query = ""
        if wantsKeyboard { focused = .source }
    }
}

/// One currency in the picker. Highlighted under the pointer like a menu item,
/// so moving down the list shows which row a click would take.
private struct CurrencyRow: View {
    let currency: CurrencyStore.Currency
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(currency.displayCode)
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .foregroundStyle(Theme.primary)
                    .frame(width: 46, alignment: .leading)
                Text(currency.name)
                    .font(.panelBody)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.primary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Theme.surfaceHover : (selected ? Theme.surface : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }
}
