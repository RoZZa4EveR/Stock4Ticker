import SwiftUI

// MARK: - Card styling helper

private extension View {
    /// Zaoblená karta ve stylu System Settings — jemná výplň + tenký okraj.
    func settingsCard() -> some View {
        self
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
    }
}

// MARK: - Popover root

struct PopoverContentView: View {

    @EnvironmentObject private var store: StockStore
    @State private var showAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            controls
            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    /// Ikona aplikace — v .app bundlu načte AppIcon, jinak systémová náhrada.
    private var appIcon: NSImage {
        NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 20, height: 20)
            Text("Stock4Ticker")
                .font(.headline)
            Spacer()
            if store.hasError {
                Image(systemName: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Offline")
            } else if store.isLoading {
                ProgressView().controlSize(.small)
            } else if let ts = store.lastUpdated {
                Text(ts.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Last updated")
            }
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh (⌘R)")
            .opacity(store.isLoading ? 0.4 : 1)
            .disabled(store.isLoading)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.stocks.isEmpty && store.isLoading {
            ProgressView("Loading data from TradingView…")
                .frame(maxWidth: .infinity, minHeight: 120)
                .settingsCard()
        } else if store.symbols.isEmpty {
            emptyState.settingsCard()
        } else if store.stocks.isEmpty && store.hasError {
            errorState.settingsCard()
        } else {
            stockSection
        }
    }

    // MARK: Stock list (card) + add button

    private var stockSection: some View {
        VStack(spacing: 10) {
            List {
                ForEach(Array(store.stocks.enumerated()), id: \.element.id) { idx, stock in
                    StockRowView(
                        stock: stock,
                        isLast: idx == store.stocks.count - 1,
                        onDelete: { withAnimation { store.removeSymbol(stock.fullSymbol) } }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .onMove { store.moveSymbol(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: listHeight)
            .padding(.vertical, 4)
            .settingsCard()

            addButton
        }
    }

    /// Výška seznamu = přesná výška řádku × počet (max 6, pak scrolluje).
    private var listHeight: CGFloat {
        min(CGFloat(store.stocks.count), 6) * StockRowView.rowHeight
    }

    private var addButton: some View {
        Button { showAddSheet = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text("Add symbol")
            }
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .background(Color.blue.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sheet(isPresented: $showAddSheet) {
            SymbolSearchSheet().environmentObject(store)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.flattrend.xyaxis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No symbols")
                .font(.title3.weight(.medium))
            Text("Add ticker symbols using the button below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add symbol") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding()
        .sheet(isPresented: $showAddSheet) {
            SymbolSearchSheet().environmentObject(store)
        }
    }

    private var errorState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Failed to load")
                .font(.headline)
            if let msg = store.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Try again") { store.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding()
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Menu bar").foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $store.showInMenuBar) {
                    Image(systemName: "arrow.clockwise").tag(MenuBarDisplay.cycling).help("Cycle")
                    Image(systemName: "arrow.left.and.right").tag(MenuBarDisplay.all).help("Side by side")
                    Image(systemName: "arrow.up.and.down").tag(MenuBarDisplay.stacked).help("Stacked")
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if store.showInMenuBar == .cycling {
                HStack {
                    Text("Cycle").foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $store.cycleInterval) {
                        Text("1s").tag(1.0 as TimeInterval)
                        Text("2s").tag(2.0 as TimeInterval)
                        Text("3s").tag(3.0 as TimeInterval)
                        Text("5s").tag(5.0 as TimeInterval)
                        Text("8s").tag(8.0 as TimeInterval)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Text("Refresh").foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $store.refreshInterval) {
                    Text("1s").tag(1.0 as TimeInterval)
                    Text("5s").tag(5.0 as TimeInterval)
                    Text("15s").tag(15.0 as TimeInterval)
                    Text("30s").tag(30.0 as TimeInterval)
                    Text("1m").tag(60.0 as TimeInterval)
                    Text("5m").tag(300.0 as TimeInterval)
                    Text("15m").tag(900.0 as TimeInterval)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .settingsCard()
        .animation(.easeInOut(duration: 0.15), value: store.showInMenuBar)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Launch at login", isOn: $store.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stock Row

struct StockRowView: View {

    /// Pevná výška řádku — sdílená s `PopoverContentView.listHeight`, aby se seznam
    /// roztáhl přesně na obsah (žádné oříznutí posledního řádku ani prázdné místo).
    static let rowHeight: CGFloat = 56

    let stock: Stock
    var isLast: Bool = false
    var onDelete: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 11) {
            // Drag handle — fades in on hover (jen v editovatelném seznamu)
            if onDelete != nil {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(isHovered ? 0.6 : 0))
                    .frame(width: 12)
            }

            Button(action: openChart) {
                HStack(spacing: 11) {
                    LogoView(url: stock.logoURL, fallbackText: stock.symbol, size: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stock.symbol)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(stock.formattedPrice)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .lineLimit(1)
                        changePill
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in TradingView")

            // Remove button — fades in on hover
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("Remove")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider().padding(.leading, onDelete != nil ? 64 : 53)
            }
        }
    }

    private var subtitle: String {
        let name = stock.name.isEmpty ? stock.fullSymbol : stock.name
        return "\(name) · \(stock.exchange)"
    }

    private var changePill: some View {
        HStack(spacing: 2) {
            Image(systemName: stock.isPositive ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text(stock.formattedChangePercent)
                .font(.system(size: 11, design: .rounded).weight(.medium))
        }
        .foregroundStyle(stock.isPositive ? Color.green : Color.red)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((stock.isPositive ? Color.green : Color.red).opacity(0.14),
                    in: Capsule())
    }

    private func openChart() {
        let sym = stock.fullSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stock.fullSymbol
        if let url = URL(string: "https://www.tradingview.com/chart/?symbol=\(sym)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Symbol Search Sheet

struct SymbolSearchSheet: View {

    @EnvironmentObject private var store: StockStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SymbolSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search symbol").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("e.g. AAPL, Tesla, BTC…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            if results.isEmpty && !query.isEmpty && !isSearching {
                ContentUnavailableView("Nothing found", systemImage: "magnifyingglass",
                    description: Text("Try a different name or ticker symbol."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { result in
                    Button {
                        store.addSymbol(result.fullName)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(result.symbol)
                                        .font(.system(.body, design: .monospaced, weight: .semibold))
                                    Text(result.exchange)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.2))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .foregroundStyle(.secondary)
                                    Text(result.typeLabel)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .foregroundStyle(.blue)
                                }
                                Text(result.description)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if store.symbols.contains(result.fullName) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                            } else {
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 500)
        .onAppear { queryFocused = true }
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        results = []
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await performSearch(q)
        }
    }

    @MainActor
    private func performSearch(_ q: String) async {
        isSearching = true
        defer { isSearching = false }
        results = (try? await TradingViewService.shared.searchSymbols(query: q)) ?? []
    }
}
