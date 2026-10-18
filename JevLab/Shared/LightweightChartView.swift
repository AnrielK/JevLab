import SwiftUI
import WebKit

/// Graf TradingView Lightweight Charts™ (přibalená JS knihovna) ve WKWebView.
/// Data se předávají jako JSON do funkce `render()`. Funguje na iOS i macOS.
struct LightweightChartView {
    /// JSON pro render(); změna JSON překreslí graf.
    let json: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false
        var pending: String?
        var last: String?
        weak var web: WKWebView?

        func push(_ json: String) {
            guard json != last else { return }
            guard loaded, let web else {
                pending = json
                return
            }
            last = json
            web.evaluateJavaScript("render(\(json))", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let p = pending {
                pending = nil
                push(p)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    fileprivate func makeWeb(_ coordinator: Coordinator) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = coordinator
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
        coordinator.web = web
        web.loadHTMLString(LightweightChartView.html, baseURL: nil)
        coordinator.push(json)
        return web
    }

    static let html: String = {
        let js = Bundle.main.url(forResource: "lightweight-charts.standalone.production", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;padding:0;height:100%;background:#0e131a;overflow:hidden}#c{position:absolute;inset:0}
        #e{color:#ff5d6c;font:12px -apple-system;padding:8px}</style></head>
        <body><div id="c"></div><script>\(js)</script><script>
        if (typeof LightweightCharts === 'undefined') { document.body.innerHTML = '<div id="e">Knihovna grafu se nenačetla.</div>'; }
        const L = LightweightCharts;
        const chart = L.createChart(document.getElementById('c'), {
          autoSize: true,
          layout: { background: { type: 'solid', color: '#0e131a' }, textColor: '#9aa4b2', attributionLogo: true },
          grid: { vertLines: { color: '#1a222d' }, horzLines: { color: '#1a222d' } },
          timeScale: { borderColor: '#1a222d', rightOffset: 4 },
          rightPriceScale: { borderColor: '#1a222d' },
          crosshair: { mode: 0 }
        });
        const candles = chart.addSeries(L.CandlestickSeries, { upColor: '#3fd68a', downColor: '#ff5d6c', borderVisible: false,
          wickUpColor: '#3fd68a', wickDownColor: '#ff5d6c' });
        const ma20 = chart.addSeries(L.LineSeries, { color: '#f5b53d', lineWidth: 1, priceLineVisible: false, lastValueVisible: false });
        const ma50 = chart.addSeries(L.LineSeries, { color: '#8b7bff', lineWidth: 2, priceLineVisible: false, lastValueVisible: false });
        const marks = L.createSeriesMarkers(candles, []);
        let lines = [];
        window.render = function (d) {
          candles.setData(d.candles); ma20.setData(d.ma20); ma50.setData(d.ma50); marks.setMarkers(d.markers);
          lines.forEach(l => candles.removePriceLine(l));
          lines = d.levels.map(l => candles.createPriceLine({ price: l.price, color: l.color, lineWidth: 1, lineStyle: 2,
            axisLabelVisible: true, title: l.title }));
          if (d.fit && d.candles.length > 0) {
            chart.timeScale().setVisibleLogicalRange({ from: Math.max(0, d.candles.length - 180), to: d.candles.length + 3 });
          }
        };
        </script></body></html>
        """
    }()
}

#if os(iOS)
extension LightweightChartView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWeb(context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.push(json) }
}
#else
extension LightweightChartView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWeb(context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) { context.coordinator.push(json) }
}
#endif
