import Foundation

// MARK: - Errors

enum TVError: Error, LocalizedError {
    case badURL
    case invalidResponse(Int)
    case parseError(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .badURL:                  return "Invalid URL"
        case .invalidResponse(let c): return "Server error (\(c))"
        case .parseError(let m):      return "Parse error: \(m)"
        case .noData:                 return "No data"
        }
    }
}

// MARK: - TradingView Service

final class TradingViewService: @unchecked Sendable {

    static let shared = TradingViewService()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Origin": "https://www.tradingview.com",
            "Referer": "https://www.tradingview.com/"
        ]
        session = URLSession(configuration: cfg)
    }

    // MARK: - Symbol normalisation
    //
    // Converts a bare symbol (no ":") to a full EXCHANGE:SYMBOL form so TradingView
    // scanner knows which market to query.
    //
    // Examples:
    //   USDCZK  → FX_IDC:USDCZK       (6-letter forex pair)
    //   BTCUSDT → BINANCE:BTCUSDT     (ends with USDT)
    //   BTCUSD  → COINBASE:BTCUSD     (ends with USD, not a forex pair)
    //   MSTR    → stays MSTR          (US stock – america scanner accepts bare tickers)
    //   BTC     → BINANCE:BTCUSDT     (well-known bare crypto token)

    func normalize(_ symbol: String) -> String {
        let upper = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !upper.isEmpty else { return upper }

        // Already has exchange prefix → leave as-is
        if upper.contains(":") { return upper }

        // ── 6-letter forex pair detection ────────────────────────────────
        // Both halves must be recognised currency ISO codes.
        let fxCodes: Set<String> = [
            "USD","EUR","GBP","JPY","CHF","AUD","CAD","NZD",
            "CZK","PLN","HUF","SEK","NOK","DKK","HKD","SGD",
            "MXN","ZAR","TRY","INR","CNH","BRL","KRW","TWD",
            "ILS","RON","BGN","ISK","SAR","AED","THB","PHP",
            "MYR","IDR","NGN","CLP","COP","PEN","CRC","UAH",
            "RUB","PKR","BDT","HRK","VND","EGP"
        ]
        if upper.count == 6 {
            let first3 = String(upper.prefix(3))
            let last3  = String(upper.suffix(3))
            if fxCodes.contains(first3) && fxCodes.contains(last3) {
                return "FX_IDC:\(upper)"   // FX_IDC má lepší pokrytí párů než FX:
            }
        }

        // ── Crypto detection ─────────────────────────────────────────────
        // Ends with USDT → Binance
        if upper.hasSuffix("USDT") && upper.count > 4 {
            return "BINANCE:\(upper)"
        }
        // Ends with USDC → Coinbase
        if upper.hasSuffix("USDC") && upper.count > 4 {
            return "COINBASE:\(upper)"
        }
        // Ends with USD (but not a 6-letter forex pair already caught above)
        // e.g. BTCUSD (6 chars but BTC not a fxCode), ETHUSD, SOLUSD
        if upper.hasSuffix("USD") && upper.count > 3 {
            return "COINBASE:\(upper)"
        }
        // Bare well-known tokens → default to Binance USDT pair
        let bareTokens: Set<String> = [
            "BTC","ETH","SOL","BNB","XRP","ADA","DOGE","DOT","AVAX",
            "MATIC","LINK","UNI","LTC","BCH","ATOM","NEAR","APT","ARB",
            "OP","FTM","SAND","MANA","AXS","SHIB","PEPE","WIF"
        ]
        if bareTokens.contains(upper) {
            return "BINANCE:\(upper)USDT"
        }

        // ── Default: US stock (america scanner handles bare tickers) ─────
        return upper
    }

    // MARK: - Quote fetch

    func fetchQuotes(for fullSymbols: [String]) async throws -> [Stock] {
        // Normalise each symbol so bare tickers get the right exchange prefix
        let normalized = fullSymbols.map { normalize($0) }

        // Group by market
        var groups: [String: [String]] = [:]
        for sym in normalized {
            let market = marketFor(sym)
            groups[market, default: []].append(sym)
        }

        // Fetch each group concurrently
        var all: [Stock] = []
        try await withThrowingTaskGroup(of: [Stock].self) { group in
            for (market, syms) in groups {
                group.addTask {
                    (try? await self.scannerFetch(symbols: syms, market: market)) ?? []
                }
            }
            for try await stocks in group {
                all.append(contentsOf: stocks)
            }
        }

        // Preserve caller's original order.
        // Match normalized symbol OR a bare symbol that resolves to "EXCHANGE:SYM"
        return normalized.compactMap { sym in
            all.first { stock in
                let sf = stock.fullSymbol.uppercased()
                let su = sym.uppercased()
                return sf == su || sf.hasSuffix(":\(su)")
            }
        }
    }

    // MARK: - Symbol search

    func searchSymbols(query: String) async throws -> [SymbolSearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        // Starý endpoint (bez /v3/) vrací přímé pole a nevyžaduje auth
        let urlStr = "https://symbol-search.tradingview.com/symbol_search/?text=\(encoded)&hl=1&lang=en&type=&exchange=&domain=production"
        guard let url = URL(string: urlStr) else { throw TVError.badURL }

        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw TVError.invalidResponse(http.statusCode)
        }

        // Odpověď je přímé JSON pole [{ symbol, description, exchange, type, source_id, ... }]
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return items.prefix(40).compactMap { item -> SymbolSearchResult? in
            guard
                let rawSymbol = item["symbol"]      as? String,
                let rawDescr  = item["description"] as? String,
                let type      = item["type"]        as? String
            else { return nil }

            // Odstraň <em>…</em> HTML tagy (TradingView je používá pro zvýraznění shody)
            let symbol = rawSymbol
                .replacingOccurrences(of: "<em>", with: "")
                .replacingOccurrences(of: "</em>", with: "")
            let descr = rawDescr
                .replacingOccurrences(of: "<em>", with: "")
                .replacingOccurrences(of: "</em>", with: "")

            // source_id je čistý exchange kód (NASDAQ, BINANCE…)
            // exchange může obsahovat čitelný název (Nasdaq Stock Market)
            let sourceId  = (item["source_id"]  as? String) ?? (item["exchange"] as? String) ?? ""
            let exchLabel = (item["exchange"]    as? String) ?? sourceId

            // Prefix z pole (pro Binance futures apod.)
            let prefix   = item["prefix"] as? String
            let fullName = prefix.map { "\($0):\(symbol)" } ?? "\(sourceId):\(symbol)"

            return SymbolSearchResult(
                symbol: symbol,
                fullName: fullName,
                description: descr,
                exchange: exchLabel,
                type: type
            )
        }
    }

    // MARK: - Market routing

    private func marketFor(_ fullSymbol: String) -> String {
        let upper = fullSymbol.uppercased()

        if upper.hasPrefix("CRYPTOCAP:") {
            return "global"
        }
        if upper.hasPrefix("BINANCE:")    || upper.hasPrefix("COINBASE:")   ||
           upper.hasPrefix("KRAKEN:")     || upper.hasPrefix("BYBIT:")      ||
           upper.hasPrefix("KUCOIN:")     || upper.hasPrefix("OKX:")        ||
           upper.hasPrefix("BITFINEX:")   || upper.hasPrefix("GEMINI:")     ||
           upper.hasPrefix("BITSTAMP:")   {
            return "crypto"
        }
        if upper.hasPrefix("FX:")         || upper.hasPrefix("FX_IDC:")     ||
           upper.hasPrefix("OANDA:")      || upper.hasPrefix("FOREXCOM:")   ||
           upper.hasPrefix("PEPPERSTONE:") {
            return "forex"
        }
        if upper.hasPrefix("CME:")        || upper.hasPrefix("COMEX:")      ||
           upper.hasPrefix("NYMEX:")      || upper.hasPrefix("CBOT:")       ||
           upper.hasPrefix("EUREX:")      || upper.hasPrefix("ICEEUR:")     ||
           upper.hasPrefix("ICEUS:")      || upper.hasPrefix("LIFFE:")      {
            return "futures"
        }
        if upper.hasPrefix("BSE:")        || upper.hasPrefix("NSE:")        {
            return "india"
        }
        if upper.hasPrefix("XETR:")       || upper.hasPrefix("FWB:")        ||
           upper.hasPrefix("AMS:")        || upper.hasPrefix("EURONEXT:")   ||
           upper.hasPrefix("LSE:")        || upper.hasPrefix("MIL:")        ||
           upper.hasPrefix("BME:")        || upper.hasPrefix("SIX:")        {
            return "europe"
        }
        if upper.hasPrefix("TSX:")        || upper.hasPrefix("TSXV:")       { return "canada" }
        if upper.hasPrefix("ASX:")        { return "australia" }
        if upper.hasPrefix("HKEX:")       { return "hongkong" }
        if upper.hasPrefix("TSE:")        || upper.hasPrefix("OSE:")        { return "japan" }

        return "america"
    }

    // MARK: - Scanner fetch

    private func scannerFetch(symbols: [String], market: String) async throws -> [Stock] {
        guard let url = URL(string: "https://scanner.tradingview.com/\(market)/scan") else {
            throw TVError.badURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let columns = ["close", "change", "change_abs", "volume", "high", "low", "open",
                       "description", "name", "exchange", "logoid", "currency",
                       "base_currency_logoid"]
        let body: [String: Any] = [
            "symbols": ["tickers": symbols],
            "columns": columns
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TVError.invalidResponse(http.statusCode)
        }

        return try parseScanner(data: data)
    }

    private func parseScanner(data: Data) throws -> [Stock] {
        guard
            let json      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataArray = json["data"] as? [[String: Any]]
        else {
            throw TVError.parseError("unexpected structure")
        }

        return dataArray.compactMap { item -> Stock? in
            guard
                let fullSymbol = item["s"] as? String,
                let values     = item["d"] as? [Any]
            else { return nil }

            // columns: close, change_pct, change_abs, volume, high, low, open, description, name, exchange, logoid
            let price         = num(values[safe: 0])
            let changePercent = num(values[safe: 1])
            let change        = num(values[safe: 2])
            let volume        = num(values[safe: 3])
            let high          = num(values[safe: 4])
            let low           = num(values[safe: 5])
            let open          = num(values[safe: 6])
            let name          = str(values[safe: 7])
            let logoIdRaw     = str(values[safe: 10])
            let currency      = str(values[safe: 11])
            let baseLogoRaw   = str(values[safe: 12])

            // Extract symbol / exchange from full name fallback
            let parts    = fullSymbol.split(separator: ":", maxSplits: 1)
            let exchange = str(values[safe: 9]).ifEmpty(String(parts[safe: 0] ?? ""))
            let symbol   = str(values[safe: 8]).ifEmpty(String(parts[safe: 1] ?? Substring(fullSymbol)))
            let logoId   = logoIdRaw.isEmpty ? nil : logoIdRaw

            return Stock(
                fullSymbol: fullSymbol,
                symbol: symbol,
                exchange: exchange,
                name: name,
                logoId: logoId,
                baseCurrencyLogoId: baseLogoRaw.isEmpty ? nil : baseLogoRaw,
                price: price,
                change: change,
                changePercent: changePercent,
                volume: volume,
                high: high,
                low: low,
                open: open,
                currency: currency
            )
        }
    }

    // MARK: - JSON helpers

    private func num(_ v: Any?) -> Double {
        guard let v else { return 0 }
        if v is NSNull { return 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String   { return Double(s) ?? 0 }
        return 0
    }

    private func str(_ v: Any?) -> String {
        guard let v else { return "" }
        if v is NSNull { return "" }
        if let s = v as? String   { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
}

// MARK: - Private helpers

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private extension Array where Element == Substring {
    subscript(safe index: Int) -> Substring? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
