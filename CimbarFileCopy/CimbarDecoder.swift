import UIKit
import WebKit

/// 解码引擎宿主：把原生采集的 RGBA 像素喂给隐藏 WKWebView 中的 cimbar 解码引擎。
/// 引擎只做纯计算（不渲染相机画面，因此不受 iOS 15.0.2 的 WKWebView 相机黑屏 bug 影响）。
/// 引擎 HTML 以内嵌 base64 直接 loadHTMLString，不依赖 Bundle 资源打包。
///
/// 分片投递：每帧像素不再拼成一条 6MB 级的 base64 源码一次性注入（WebKit 要为它分配多份大字符串，
/// 大文件传到一半容易把 WebContent 进程压死），而是拆成 begin + N 段 append + end，单次注入 ≤ 0.5MB。
/// 文件回传同样分块：JS 每读到 128KB 就推一块，这里边收边写盘，峰值内存不再翻倍。
final class CimbarDecoder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    var onLog: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onFile: ((URL, String) -> Void)?
    var onMode: ((Int) -> Void)?
    var onEngineLost: (() -> Void)?

    let webView: WKWebView
    private var ready = false
    private var dead = false
    private var busy = false
    private var jsErrorStreak = 0
    private var probeTimer: Timer?
    private var probeState = 0   // 0=未执行 1=页面已执行 2=引擎对象已建 3=引擎就绪

    /// 每段原始像素字节数（整段 base64 后约 0.51MB）；4.66MB 的 1080 帧分成 13 段
    static let chunkBytes = 384_000

    // 流式落盘
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var fileName = ""
    private var fileExpected = 0
    private var fileWritten = 0

    var isReady: Bool { ready && !dead }

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
        guard let data = Data(base64Encoded: DecoderHTML.base64),
              let html = String(data: data, encoding: .utf8) else {
            onLog?("内嵌引擎解码失败")
            return
        }
        onLog?("内嵌引擎已解出 (\(html.count) 字符)")
        webView.loadHTMLString(html, baseURL: nil)
        startProbe()
    }

    /// 每 2 秒主动探测一次引擎状态（检查我们自己的脚本是否真正执行，规避空页面误报）。
    private func startProbe() {
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.probe() }
        probeTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func probe() {
        guard !dead else { return }
        let js = "(function(){return {br:(typeof window.CimbarBridge !== 'undefined')?1:0, cim:(typeof window.__cim !== 'undefined')?1:0, mod:(typeof Module !== 'undefined' && typeof Module._cimbard_get_bufsize === 'function')?1:0};})()"
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
            let br = (d["br"] as? NSNumber)?.intValue ?? 0
            let cim = (d["cim"] as? NSNumber)?.intValue ?? 0
            let mod = (d["mod"] as? NSNumber)?.intValue ?? 0
            var state = 0
            if br == 1 { state = 1 }
            if cim == 1 { state = 2 }
            if mod == 1 { state = 3 }
            if state > self.probeState {
                self.probeState = state
                let labels = ["", "引擎页面已执行(探针)", "引擎对象已创建(探针)", "引擎就绪(探针)"]
                self.onLog?(labels[state])
            }
            if state == 3 && !self.ready {
                self.ready = true
                self.onLog?("引擎就绪(探针)")
            }
        }
    }

    // MARK: - 分片投递一帧

    /// 把一帧 RGBA 像素交给 JS 引擎；completion 在该帧处理完后回调（帧节流信号）。
    /// JS 是单线程：上一帧的分片序列还没走完就直接丢掉这一帧，避免两次投递的偏移互相踩。
    func feedFrame(data: Data, width: Int, height: Int, completion: @escaping () -> Void) {
        guard ready, !dead else {
            completion()
            return
        }
        guard !busy else {
            completion()
            return
        }
        busy = true
        let total = data.count
        evaluate("CimbarBridge.begin(\(width), \(height), \(total));") { [weak self] ok in
            guard let self = self else { completion(); return }
            guard ok else { self.busy = false; completion(); return }
            self.pushChunks(data, from: 0, completion: completion)
        }
    }

    private func pushChunks(_ data: Data, from offset: Int, completion: @escaping () -> Void) {
        if offset >= data.count {
            evaluate("CimbarBridge.end();") { [weak self] _ in
                self?.busy = false
                completion()
            }
            return
        }
        let end = min(offset + Self.chunkBytes, data.count)
        let piece = data.subdata(in: offset..<end)
        let b64 = piece.base64EncodedString()
        evaluate("CimbarBridge.append(\"\(b64)\");") { [weak self] ok in
            guard let self = self else { completion(); return }
            guard ok else { self.busy = false; completion(); return }
            self.pushChunks(data, from: end, completion: completion)
        }
    }

    /// 统一入口：失败计数 + 连续失败判定引擎已废（不再对着空气喂帧）。
    private func evaluate(_ js: String, done: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript(js) { [weak self] _, error in
            guard let self = self else { done(false); return }
            if let error = error {
                self.jsErrorStreak += 1
                self.onLog?("JS 调用失败(第\(self.jsErrorStreak)次): \(error.localizedDescription)")
                if self.jsErrorStreak >= 5 {
                    self.declareDead(reason: "连续 \(self.jsErrorStreak) 次 JS 调用失败")
                }
                done(false)
                return
            }
            self.jsErrorStreak = 0
            done(true)
        }
    }

    private func declareDead(reason: String) {
        guard !dead else { return }
        dead = true
        ready = false
        busy = false
        onLog?("引擎已失效（\(reason)）：本次传输中断，点「停止接收」再重新开始")
        onEngineLost?()
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

    /// 关键诊断钩子：WebContent 进程被系统回收（多半是内存压力）时一定会走这里。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onLog?("引擎进程已被系统回收（内存压力）")
        declareDead(reason: "进程被系统回收")
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
        case "err":
            onLog?("JS 内部错误: \(body["msg"] as? String ?? "?")")
        case "mode":
            if let mode = body["mode"] as? Int {
                onMode?(mode)
            }
        case "progress":
            if let report = body["report"] as? [NSNumber] {
                let maxFraction = report.map { $0.doubleValue }.max() ?? 0
                onProgress?(maxFraction)
            }
        case "filebegin":
            let raw = (body["name"] as? String) ?? "received.bin"
            let safe = (raw as NSString).lastPathComponent
            fileName = safe.isEmpty ? "received.bin" : safe
            fileExpected = (body["size"] as? NSNumber)?.intValue ?? 0
            fileWritten = 0
            fileHandle?.closeFile()
            fileHandle = nil
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileURL = url
            fileHandle = try? FileHandle(forWritingTo: url)
            onLog?("文件开始落盘 \(fileName)（预计 \(fileExpected) 字节）")
        case "filechunk":
            guard let b64 = body["base64"] as? String,
                  let d = Data(base64Encoded: b64) else { return }
            fileHandle?.write(d)
            fileWritten += d.count
        case "fileend":
            fileHandle?.closeFile()
            fileHandle = nil
            guard let url = fileURL else { return }
            fileURL = nil
            onLog?("文件已写入 \(fileWritten) 字节 → \(fileName)")
            onFile?(url, fileName)
        default:
            break
        }
    }
}
