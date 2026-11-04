import UIKit
import WebKit

/// 解码引擎宿主：把原生采集的 RGBA 像素喂给隐藏 WKWebView 中的 cimbar 解码引擎，
/// 引擎只做纯计算（不渲染相机画面，因此不受 iOS 15.0.2 的 WKWebView 相机黑屏 bug 影响）。
final class CimbarDecoder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    var onLog: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onFile: ((URL, String) -> Void)?

    let webView: WKWebView
    private var ready = false

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        webView = wv
        super.init()

        wv.navigationDelegate = self
        controller.add(self, name: "cimbar")

        // 资源自检：确认三个引擎文件都进了 App 包
        let checks: [(String, String)] = [("decoder", "html"), ("cimbar_js", "js"), ("wasm_b64", "js")]
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
            wv.loadFileURL(url, allowingReadAccessTo: Bundle.main.bundleURL)
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

    // MARK: - WKNavigationDelegate（加载状态日志，便于定位问题）

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
