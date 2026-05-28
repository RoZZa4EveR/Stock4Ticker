import Foundation

// MARK: - Locale-safe formatter
// String(format: "%.2f") respects LC_NUMERIC – Czech locale uses comma.
// Always force en_US so we get "178.52" not "178,52".

private let _enLocale = Locale(identifier: "en_US")

private extension Double {
    func fmt(_ decimals: Int) -> String {
        self.formatted(
            .number
            .precision(.fractionLength(decimals))
            .locale(_enLocale)
        )
    }
}

// MARK: - Stock

struct Stock: Identifiable, Equatable, Codable {
    let id: String          // fullSymbol e.g. "NASDAQ:AAPL"
    let fullSymbol: String  // "NASDAQ:AAPL"
    let symbol: String      // "AAPL"
    let exchange: String    // "NASDAQ"
    var name: String        // "Apple Inc"
    var logoId: String?     // TradingView logo identifier e.g. "apple"
    var baseCurrencyLogoId: String?  // forex/crypto base, e.g. "country/US", "crypto/XTVCBTC"
    var price: Double
    var change: Double      // absolute change
    var changePercent: Double
    var volume: Double
    var high: Double
    var low: Double
    var open: Double
    var currency: String    // listing currency ISO code e.g. "USD", "EUR", "JPY"

    init(
        fullSymbol: String,
        symbol: String,
        exchange: String,
        name: String = "",
        logoId: String? = nil,
        baseCurrencyLogoId: String? = nil,
        price: Double = 0,
        change: Double = 0,
        changePercent: Double = 0,
        volume: Double = 0,
        high: Double = 0,
        low: Double = 0,
        open: Double = 0,
        currency: String = ""
    ) {
        self.id = fullSymbol
        self.fullSymbol = fullSymbol
        self.symbol = symbol
        self.exchange = exchange
        self.name = name
        self.logoId = logoId
        self.baseCurrencyLogoId = baseCurrencyLogoId
        self.price = price
        self.change = change
        self.changePercent = changePercent
        self.volume = volume
        self.high = high
        self.low = low
        self.open = open
        self.currency = currency
    }

    /// URL loga z TradingView CDN (SVG, podporováno macOS 12+)
    var logoURL: URL? {
        // 1) Logoid z API (akcie jako MSTR)
        if let lid = logoId, !lid.isEmpty {
            return URL(string: "https://s3-symbol-logo.tradingview.com/\(lid)--big.svg")
        }
        // 2) Base currency logoid z API — vlajka u forexu (country/US), token u crypto
        //    (crypto/XTVCBTC). Pokrývá páry, které nemají vlastní logoid.
        if let blid = baseCurrencyLogoId, !blid.isEmpty {
            return URL(string: "https://s3-symbol-logo.tradingview.com/\(blid)--big.svg")
        }
        // 3) Crypto: odvoď z páru — BTCUSD → crypto/XTVCBTC
        let exch = exchange.uppercased()
        let cryptoExchanges: Set<String> = ["BINANCE","COINBASE","KRAKEN","BYBIT","KUCOIN","OKX","BITFINEX","BITSTAMP","GEMINI"]
        if cryptoExchanges.contains(exch) {
            let sym = symbol.uppercased()
            for suffix in ["USDT","USDC","BUSD","USD","BTC","ETH","BNB"] {
                if sym.hasSuffix(suffix), sym.count > suffix.count {
                    let base = String(sym.dropLast(suffix.count))
                    return URL(string: "https://s3-symbol-logo.tradingview.com/crypto/XTVC\(base)--big.svg")
                }
            }
            // Bare token (BTC, ETH, ...)
            return URL(string: "https://s3-symbol-logo.tradingview.com/crypto/XTVC\(sym)--big.svg")
        }
        return nil
    }

    // MARK: Formatted helpers

    /// Returns true when price data was actually received.
    var hasData: Bool { price > 1e-10 }

    /// Wraps a formatted number string with the correct currency symbol.
    /// Empty `currency` → no symbol (never fake "$").
    func withCurrency(_ s: String) -> String {
        switch currency.uppercased() {
        case "USD", "AUD", "CAD", "NZD", "HKD", "SGD", "MXN": return "$" + s
        case "EUR":          return "€" + s
        case "GBP", "GBX":   return "£" + s
        case "JPY", "CNY", "CNH": return "¥" + s
        case "CHF":          return "CHF " + s
        case "INR":          return "₹" + s
        case "KRW":          return "₩" + s
        case "RUB":          return "₽" + s
        case "TRY":          return "₺" + s
        case "BRL":          return "R$" + s
        case "ZAR":          return "R" + s
        case "PLN":          return s + " zł"
        case "CZK":          return s + "Kč"
        case "SEK", "NOK", "DKK": return s + " kr"
        case "":             return s
        default:             return s + " " + currency.uppercased()
        }
    }

    var formattedPrice: String {
        guard hasData else { return "—" }
        if price >= 1    { return withCurrency(price.fmt(2)) }
        if price >= 0.01 { return withCurrency(price.fmt(4)) }
        return withCurrency(price.fmt(6))
    }

    var formattedChange: String {
        guard abs(change) > 1e-10 else { return "—" }
        let sign = change >= 0 ? "+" : ""
        return sign + change.fmt(2)
    }

    var formattedChangePercent: String {
        guard abs(changePercent) > 1e-10 else { return hasData ? "0.00%" : "—" }
        let sign = changePercent >= 0 ? "+" : ""
        return sign + changePercent.fmt(2) + "%"
    }

    var formattedVolume: String {
        guard volume > 0 else { return "—" }
        if volume >= 1_000_000_000 { return (volume / 1_000_000_000).fmt(2) + "B" }
        if volume >= 1_000_000     { return (volume / 1_000_000).fmt(2) + "M" }
        if volume >= 1_000         { return (volume / 1_000).fmt(1) + "K" }
        return volume.fmt(0)
    }

    var isPositive: Bool { changePercent >= 0 }
}

// MARK: - Symbol search result

struct SymbolSearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let symbol: String
    let fullName: String   // "NASDAQ:AAPL"
    let description: String
    let exchange: String
    let type: String

    var typeLabel: String {
        switch type.lowercased() {
        case "stock":   return "Stock"
        case "fund":    return "ETF"
        case "crypto":  return "Crypto"
        case "forex":   return "Forex"
        case "index":   return "Index"
        case "futures": return "Futures"
        default:        return type.capitalized
        }
    }
}

// MARK: - Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
