import UIKit
import WebKit

/// 解码引擎宿主：把原生采集的 RGBA 像素喂给隐藏 WKWebView 中的 cimbar 解码引擎。
/// 引擎只做纯计算（不渲染相机画面，因此不受 iOS 15.0.2 的 WKWebView 相机黑屏 bug 影响）。
final class CimbarDecoder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    var onLog: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onFile: ((URL, String) -> Void)?

    let webView: WKWebView
    private var ready = false
    private var probeTimer: Timer?
    private var probeState = 0   // 0=未知 1=页面已加载 2=引擎对象已建 3=引擎就绪 4=页面不可达

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.alpha = 0.01
        webView = wv
        super.init()

        wv.navigationDelegate = self
        controller.add(self, name: "cimbar")
    }

    /// 由 ViewController 在回调接好之后调用（保证所有日志都能显示）。
    func start() {
        let checks: [(String, String)] = [("decoder", "html"), ("cimbar_js", "js")]
        var missing: [String] = []
        for (name, ext) in checks {
            if Bundle.main.url(forResource: name, withExtension: ext) == nil {
                missing.append(name + "." + ext)
            }
        }
        if missing.isEmpty {
            onLog?("资源检查 OK")
        } else {
            onLog?("资源缺失: " + missing.joined(separator: ", "))
        }

        if let url = Bundle.main.url(forResource: "decoder", withExtension: "html") {
            onLog?("加载 decoder.html")
            webView.loadFileURL(url, allowingReadAccessTo: Bundle.main.bundleURL)
        } else {
            onLog?("decoder.html 不在包内")
        }
        startProbe()
    }

    /// 每 2 秒主动探测一次页面/引擎状态，不依赖 JS 主动上报，避免日志被吞。
    private func startProbe() {
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.probe() }
        probeTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func probe() {
        let js = "(function(){return {rs: document.readyState, cim: (typeof window.__cim !== 'undefined') ? 1 : 0, mod: (typeof Module !== 'undefined' && typeof Module._cimbard_get_bufsize === 'function') ? 1 : 0};})()"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                if self.probeState < 4 {
                    self.probeState = 4
                    self.onLog?("JS 探针: 页面不可达 - \(error.localizedDescription)")
                }
                return
            }
            guard let d = result as? [String: Any] else { return }
            let rs = d["rs"] as? String ?? ""
            let cim = (d["cim"] as? NSNumber)?.intValue ?? 0
            let mod = (d["mod"] as? NSNumber)?.intValue ?? 0
            var state = 0
            if rs == "complete" { state = 1 }
            if cim == 1 { state = 2 }
            if mod == 1 { state = 3 }
            if state > self.probeState {
                self.probeState = state
                let labels = ["", "页面已加载(探针)", "引擎对象已创建(探针)", "引擎就绪(探针)"]
                self.onLog?(labels[state])
            }
            if state == 3 && !self.ready {
                self.ready = true
                self.onLog?("引擎就绪(探针)")
            }
        }
    }

    /// 同步把一帧 RGBA 像素交给 JS 引擎；completion 在 JS 处理完该帧后回调（帧节流信号）。
    func feedFrame(base64: String, width: Int, height: Int, completion: @escaping () -> Void) {
        guard ready else {
            completion()
            return
        }
        let js = "CimbarBridge.feed(\"\(base64)\", \(width), \(height));"
        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error = error {
                self?.onLog?("JS 执行错误: \(error.localizedDescription)")
            }
            completion()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLog?("页面加载完成")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLog?("页面加载失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onLog?("页面加载失败(初始): \(error.localizedDescription)")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "cimbar",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            ready = true
            onLog?("解码引擎就绪")
        case "log":
            onLog?(body["msg"] as? String ?? "")
        case "progress":
            if let report = body["report"] as? [NSNumber] {
                let maxFraction = report.map { $0.doubleValue }.max() ?? 0
                onProgress?(maxFraction)
            }
        case "file":
            guard let name = body["name"] as? String,
                  let b64 = body["base64"] as? String,
                  let data = Data(base64Encoded: b64) else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try data.write(to: url)
            } catch {
                onLog?("文件保存失败: \(error.localizedDescription)")
                return
            }
            onFile?(url, name)
        default:
            break
        }
    }
}
