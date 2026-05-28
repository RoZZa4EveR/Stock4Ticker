import SwiftUI
import AppKit
import Combine

// MARK: - AppDelegate (NSStatusItem + NSPopover přístup)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    let store = StockStore()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()
    private var cycleTimer: Timer?
    private var currentIndex = 0
    /// Když je popover otevřený, lišta se zmrazí (updateLabel se vrátí hned) a
    /// cyklování se pozastaví — aby se neměnila šířka status itemu a ukotvený
    /// popover necukal. Při zavření se vše sesynchronizuje.
    private var isPopoverOpen = false
    /// Globální monitor myši — `.transient` u accessory appky nezavře popover při
    /// kliknutí do jiné appky (nejsme aktivní). Monitor to dožene.
    private var clickMonitor: Any?
    /// Vlastní NSView pro mód "pod sebou" — přidána jako subview buttonu
    private var stackedCustomView: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()

        // Sleduj změny a aktualizuj lištu. Když je popover otevřený, updateLabel()
        // se vrátí hned (lišta je zmrazená) a vše se dožene při zavření.
        store.$stocks
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &cancellables)

        store.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &cancellables)

        store.$showInMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &cancellables)

        store.$cycleInterval
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startCycleTimer() }
            .store(in: &cancellables)

        startCycleTimer()
        store.startRefreshing()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let btn = statusItem.button else { return }
        btn.title = "📈"
        btn.action = #selector(togglePopover)
        btn.target = self
    }

    // MARK: - Label update

    private func updateLabel() {
        guard let btn = statusItem?.button else { return }
        // Dokud je popover otevřený, lištu nepřekreslujeme — měnící se šířka status
        // itemu by ukotveným popoverem cukala. Vše se sesynchronizuje při zavření.
        if isPopoverOpen { return }

        // Loading/empty stav
        if store.isLoading && store.stocks.isEmpty {
            clearStackedView(btn: btn)
            btn.title = "📈 …"
            return
        }
        guard !store.stocks.isEmpty else {
            clearStackedView(btn: btn)
            btn.title = "📈"
            return
        }

        let idx = store.stocks.indices.contains(currentIndex) ? currentIndex : 0
        let stock = store.stocks[idx]

        switch store.showInMenuBar {
        case .cycling:
            clearStackedView(btn: btn)
            btn.attributedTitle = makeAttrTitle(stock)

        case .all:
            clearStackedView(btn: btn)
            let combined = NSMutableAttributedString()
            for (i, s) in store.stocks.enumerated() {
                combined.append(makeAttrTitle(s))
                if i < store.stocks.count - 1 {
                    combined.append(NSAttributedString(string: "   "))
                }
            }
            btn.attributedTitle = combined

        case .stacked:
            // Vlastní NSView: symbol nahoře, cena dole, tickery vedle sebe
            buildStackedView(btn: btn)
        }
    }

    // MARK: - Stacked NSView layout

    /// Vyčistí vlastní stacked subview a obnoví normální délku statusItem.
    private func clearStackedView(btn: NSStatusBarButton) {
        guard stackedCustomView != nil else { return }
        stackedCustomView?.removeFromSuperview()
        stackedCustomView = nil
        statusItem.length = NSStatusItem.variableLength
        btn.title = ""
    }

    /// Sestaví (nebo překreslí) vlastní 2-řádkový layout pro mód "pod sebou".
    private func buildStackedView(btn: NSStatusBarButton) {
        stackedCustomView?.removeFromSuperview()

        let barH   = NSStatusBar.system.thickness      // výška lišty (24 na Retina, 22 jinak)
        let rowH   = floor((barH - 4) / 2)            // výška jednoho řádku
        let sz     = rowH * 0.88                       // velikost písma ≈ 88 % výšky řádku
        let font   = NSFont.monospacedSystemFont(ofSize: sz, weight: .regular)
        let bold   = NSFont.monospacedSystemFont(ofSize: sz, weight: .semibold)
        // Cena proporcionálním fontem — monospaced ve status baru mísí diakritiku
        // (háček u „Kč" uletí); proporcionální systémový font kreslí „č" správně.
        let priceFont = NSFont.systemFont(ofSize: sz)
        let hPad: CGFloat = 4
        let hGap: CGFloat = 10

        // Změř šířku každého sloupce
        func measure(_ s: String, _ f: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: f]).width
        }
        let colW: [CGFloat] = store.stocks.map { stock in
            max(measure(stock.symbol, bold),
                measure(stock.formattedPrice + " ", priceFont) + measure(stock.formattedChangePercent, font))
        }

        // Ikona (logo/monogram) vlevo od každého sloupce.
        let logoSize = floor(barH * 0.62)
        let logoGap: CGFloat = 4
        let lw = logoSize + logoGap

        let totalW = colW.reduce(0, +) + lw * CGFloat(store.stocks.count)
            + hGap * CGFloat(store.stocks.count - 1) + hPad * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: barH))

        var x = hPad
        for (i, stock) in store.stocks.enumerated() {
            let w = colW[i]
            let changeColor: NSColor = stock.isPositive ? .systemGreen : .systemRed

            // Ikona (vertikálně vystředěná, kruhový ořez)
            let iv = NSImageView(frame: NSRect(x: x, y: (barH - logoSize) / 2,
                                               width: logoSize, height: logoSize))
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = logoSize / 2
            iv.layer?.masksToBounds = true
            iv.image = menuBarIcon(for: stock, size: logoSize)
            container.addSubview(iv)
            let tx = x + lw

            // Horní řádek — symbol tučně
            let symTF = NSTextField(labelWithString: stock.symbol)
            symTF.font = bold
            symTF.textColor = .labelColor
            symTF.frame = NSRect(x: tx, y: 2 + rowH, width: w + 2, height: rowH)
            container.addSubview(symTF)

            // Dolní řádek — cena + změna
            let priceAttr = NSMutableAttributedString(
                string: stock.formattedPrice + " ",
                attributes: [.font: priceFont, .foregroundColor: NSColor.labelColor]
            )
            priceAttr.append(NSAttributedString(
                string: stock.formattedChangePercent,
                attributes: [.font: font, .foregroundColor: changeColor]
            ))
            let priceTF = NSTextField(labelWithAttributedString: priceAttr)
            priceTF.frame = NSRect(x: tx, y: 2, width: w + 20, height: rowH)
            container.addSubview(priceTF)

            x = tx + w + hGap
        }

        // Skryj text buttonu a vlož container jako subview
        btn.title = ""
        btn.attributedTitle = NSAttributedString()
        btn.addSubview(container)
        statusItem.length = totalW
        stackedCustomView = container
    }

    // MARK: - Attr title helpers

    /// Zmenší logo na kruhový badge dané velikosti (pro lištu).
    private func menuBarBadge(_ image: NSImage, size: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: size, height: size))
        out.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(ovalIn: rect).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        out.unlockFocus()
        return out
    }

    /// Kolečko s monogramem (první písmeno symbolu) — fallback pro symboly bez loga.
    private func monogramBadge(_ text: String, size: CGFloat) -> NSImage {
        let letter = String(text.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        let out = NSImage(size: NSSize(width: size, height: size))
        out.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.55, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let s = letter as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (size - sz.width) / 2, y: (size - sz.height) / 2), withAttributes: attrs)
        out.unlockFocus()
        return out
    }

    /// Ikona pro lištu: logo (pokud načtené), jinak monogram kolečko.
    private func menuBarIcon(for stock: Stock, size: CGFloat) -> NSImage {
        if let url = stock.logoURL,
           let img = LogoLoader.shared.image(for: url, onLoad: { [weak self] in self?.updateLabel() }) {
            return menuBarBadge(img, size: size)
        }
        return monogramBadge(stock.symbol, size: size)
    }

    private func makeAttrTitle(_ stock: Stock) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
        let changeColor: NSColor = stock.isPositive ? .systemGreen : .systemRed

        let result = NSMutableAttributedString()
        // Ikona (logo nebo monogram) jako inline příloha
        let s: CGFloat = 14
        let att = NSTextAttachment()
        att.image = menuBarIcon(for: stock, size: s)
        att.bounds = CGRect(x: 0, y: -3, width: s, height: s)
        result.append(NSAttributedString(attachment: att))
        result.append(NSAttributedString(string: " "))
        result.append(NSAttributedString(string: stock.symbol + " ",
            attributes: [.font: boldFont]))
        // Cena proporcionálním fontem (ne monospaced) — ve status baru monospaced
        // mísí diakritiku a háček u „Kč" uletí; systémový font kreslí „č" správně.
        result.append(NSAttributedString(string: stock.formattedPrice + " ",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))]))
        result.append(NSAttributedString(string: stock.formattedChangePercent,
            attributes: [.font: font, .foregroundColor: changeColor]))
        return result
    }

    // MARK: - Cycle timer

    private func startCycleTimer() {
        cycleTimer?.invalidate()
        // Když je popover otevřený, necyklujeme — měnící se šířka status itemu by
        // ukotveným popoverem cukala. Explicitní změny (mód, symboly, refresh) ale
        // projdou normálně přes updateLabel().
        guard !isPopoverOpen else { return }
        cycleTimer = Timer.scheduledTimer(withTimeInterval: store.cycleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceTicker() }
        }
    }

    private func advanceTicker() {
        guard !store.stocks.isEmpty else { return }
        currentIndex = (currentIndex + 1) % store.stocks.count
        updateLabel()
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = PopoverContentView()
            .environmentObject(store)
        popover.contentViewController = NSHostingController(rootView: root)
        popover.contentViewController?.view.frame = NSRect(x: 0, y: 0, width: 360, height: 500)
    }

    @objc private func togglePopover() {
        guard let btn = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Zmraz lištu (cyklování + překreslování), ať se status item a tím kotva
            // popoveru nehýbe, dokud je otevřený.
            isPopoverOpen = true
            cycleTimer?.invalidate()
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Zavři při kliknutí kamkoli mimo (jiná appka / plocha).
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        // Odeber monitor, rozmraz lištu, sesynchronizuj obsah a rozjeď cyklování.
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        isPopoverOpen = false
        updateLabel()
        startCycleTimer()
    }
}

// MARK: - App

@main
struct Stock4TickerApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Lišta je řízena NSStatusItem v AppDelegate – žádná scéna není potřeba.
        // Prázdná Settings scéna zajistí, že app nemá Dock ikonu ani hlavní okno.
        Settings { EmptyView() }
    }
}
