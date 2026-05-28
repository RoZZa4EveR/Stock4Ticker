import Foundation
import Combine
import ServiceManagement

// MARK: - StockStore

@MainActor
final class StockStore: ObservableObject {

    // MARK: Published state
    @Published var stocks: [Stock] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var hasError = false
    @Published var errorMessage: String?

    // Settings
    @Published var symbols: [String] = [] { didSet { saveSettings() } }
    @Published var refreshInterval: TimeInterval = 30 { didSet { saveSettings(); rescheduleRefresh() } }
    @Published var showInMenuBar: MenuBarDisplay = .cycling { didSet { saveSettings() } }
    @Published var cycleInterval: TimeInterval = 3 { didSet { saveSettings() } }

    // Launch at login — backed by SMAppService, not UserDefaults
    @Published var launchAtLogin = false {
        didSet {
            guard !isLoadingSettings, launchAtLogin != oldValue else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    // MARK: Private
    private let service = TradingViewService.shared
    private var refreshTask: Task<Void, Never>?
    private var started = false
    private var isLoadingSettings = false
    // Explicitní suite name zajistí persistenci jak při swift run, tak v .app bundlu
    private let ud = UserDefaults(suiteName: "cz.stock4ticker.app") ?? .standard

    // MARK: Init

    init() {
        loadSettings()
        if symbols.isEmpty {
            symbols = ["COINBASE:BTCUSD"]
        }
        // Reflect the actual SMAppService registration, not a stored flag
        isLoadingSettings = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isLoadingSettings = false
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            dbg("launchAtLogin -> \(enabled)")
        } catch {
            dbg("launchAtLogin CHYBA: \(error)")
            // Revert the toggle to the real state on failure
            isLoadingSettings = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isLoadingSettings = false
        }
    }

    // MARK: Public API

    func startRefreshing() {
        guard !started else { return }
        started = true
        dbg("startRefreshing")
        Task { await fetchStocks() }
        rescheduleRefresh()
    }

    func refresh() {
        guard !isLoading else { return }
        Task { await fetchStocks() }
    }

    func addSymbol(_ symbol: String) {
        let normalized = service.normalize(symbol.trimmingCharacters(in: .whitespaces))
        guard !normalized.isEmpty, !symbols.contains(normalized) else { return }
        symbols.append(normalized)
        Task { await fetchStocks() }
    }

    func removeSymbol(_ symbol: String) {
        symbols.removeAll { $0 == symbol }
        stocks.removeAll { $0.fullSymbol == symbol || $0.fullSymbol.hasSuffix(":\(symbol)") }
    }

    func moveSymbol(from: IndexSet, to: Int) {
        symbols.move(fromOffsets: from, toOffset: to)
        let ordered = symbols.compactMap { sym in
            stocks.first { $0.fullSymbol == sym || $0.fullSymbol.hasSuffix(":\(sym)") }
        }
        stocks = ordered
    }

    // MARK: Private helpers

    private func fetchStocks() async {
        dbg("fetchStocks – symboly: \(symbols)")
        guard !symbols.isEmpty else { return }
        isLoading = true
        hasError = false
        errorMessage = nil
        do {
            let fetched = try await service.fetchQuotes(for: symbols)
            dbg("OK: \(fetched.map { "\($0.symbol)=\($0.price)" })")
            stocks = fetched
            lastUpdated = Date()
            if let encoded = try? JSONEncoder().encode(fetched) {
                ud.set(encoded, forKey: Keys.cachedQuotes)
            }
        } catch {
            dbg("CHYBA: \(error)")
            hasError = true
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func rescheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { break }
                await fetchStocks()
            }
        }
    }

    // MARK: Persistence

    private enum Keys {
        static let symbols         = "tv_symbols"
        static let refreshInterval = "tv_refreshInterval"
        static let showInMenuBar   = "tv_showInMenuBar"
        static let cycleInterval   = "tv_cycleInterval"
        static let cachedQuotes    = "tv_cachedQuotes"
    }

    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        if let data = ud.data(forKey: Keys.symbols),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            symbols = decoded.map { service.normalize($0) }
        }
        // Poslední známé ceny → lišta naběhne hned, bez čekání na první fetch.
        // Bereme jen hodnoty pro aktuálně uložené symboly a ve správném pořadí.
        if let data = ud.data(forKey: Keys.cachedQuotes),
           let cached = try? JSONDecoder().decode([Stock].self, from: data) {
            stocks = symbols.compactMap { sym in
                cached.first { $0.fullSymbol == sym || $0.fullSymbol.hasSuffix(":\(sym)") }
            }
        }
        let ri = ud.double(forKey: Keys.refreshInterval)
        refreshInterval = ri > 0 ? ri : 30
        let ci = ud.double(forKey: Keys.cycleInterval)
        cycleInterval = ci > 0 ? ci : 3
        if let raw = ud.string(forKey: Keys.showInMenuBar),
           let val = MenuBarDisplay(rawValue: raw) {
            showInMenuBar = val
        }
    }

    private func saveSettings() {
        guard !isLoadingSettings else { return }
        if let encoded = try? JSONEncoder().encode(symbols) {
            ud.set(encoded, forKey: Keys.symbols)
        }
        ud.set(refreshInterval, forKey: Keys.refreshInterval)
        ud.set(cycleInterval, forKey: Keys.cycleInterval)
        ud.set(showInMenuBar.rawValue, forKey: Keys.showInMenuBar)
    }

    private func dbg(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        let url = URL(fileURLWithPath: "/tmp/stock4ticker.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - MenuBarDisplay

enum MenuBarDisplay: String, CaseIterable {
    case cycling = "cycling"
    case all     = "all"
    case stacked = "stacked"

    var label: String {
        switch self {
        case .cycling: return "Cycle"
        case .all:     return "Side by side"
        case .stacked: return "Stacked"
        }
    }
}
