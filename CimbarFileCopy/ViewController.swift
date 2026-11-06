import UIKit
import AVFoundation
import Accelerate
import Darwin

final class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cimbar.camera.session")
    private let frameQueue = DispatchQueue(label: "cimbar.camera.frames")
    private var decoder: CimbarDecoder?
    private var previewLayer = AVCaptureVideoPreviewLayer()

    private var isRunning = false
    private var inflight = 0                 // 在途帧数（允许重叠，提升帧率）
    private let maxInflight = 3
    private var frameCount = 0
    private var fpsMark = Date()
    private var frameCheckTimer: Timer?

    private var logLines: [String] = []

    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let logView = UITextView()
    private let toggleButton = UIButton(type: .system)
    private let enginePreview = UIImageView()   // 引擎实时视角小窗（显示送进引擎的帧）
    private let crosshairView = UIView()        // 瞄准准星框（条码需填满此框）
    private var crosshairAspect: CGFloat = 1.0
    private let crosshairLayer = CAShapeLayer()
    private var didLogFormat = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)

        // 隐藏的解码 WKWebView：1×1、近乎透明，不遮挡相机预览；引擎只做计算
        let dec = CimbarDecoder()
        decoder = dec
        view.addSubview(dec.webView)
        dec.webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)

        setupUI()

        // 先接回调，再启动引擎（保证每一行日志都能显示）
        dec.onLog = { [weak self] text in
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        dec.onProgress = { [weak self] fraction in
            DispatchQueue.main.async {
                self?.progressView.progress = Float(fraction)
                self?.progressLabel.text = String(format: "已接收 %.0f%%", fraction * 100)
            }
        }
        dec.onFile = { [weak self] url, name in
            DispatchQueue.main.async {
                let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                avc.popoverPresentationController?.sourceView = self?.view
                avc.popoverPresentationController?.sourceRect = self?.view.bounds ?? .zero
                self?.present(avc, animated: true, completion: nil)
            }
        }
        dec.onMode = { [weak self] mode in
            DispatchQueue.main.async {
                var aspect: CGFloat = 1.0
                if mode == 66 { aspect = 1.1516 }        // Bu
                else if mode == 67 { aspect = 1.413 }    // Bm
                self?.crosshairAspect = aspect
                self?.view.setNeedsLayout()
            }
        }
        // 引擎被系统回收或连续失败：立刻停采集，别对着空气喂帧
        dec.onEngineLost = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isRunning { self.stop() }
                self.statusLabel.text = "引擎中断，请点「开始接收」重新开始"
                self.progressLabel.text = "尚未开始"
                self.appendLog("已停止采集：引擎不可用，需重新开始")
            }
        }
        dec.start()
        appendLog("等待解码引擎就绪…")

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureCamera() } else { self?.showPermissionHint() }
                }
            }
        default:
            showPermissionHint()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 相机预览跟随视图尺寸（旋转、第一次布局都会触发）
        previewLayer.frame = view.bounds
        updateCrosshairPath()
    }

    /// 准星框：条码应填满此框（宽=画面宽，高=宽×模式比例，与网页端一致）
    private func updateCrosshairPath() {
        let bounds = view.bounds
        let margin: CGFloat = 12
        let rectWidth = bounds.width - margin * 2
        let rectHeight = rectWidth * crosshairAspect
        let rect = CGRect(x: margin,
                          y: (bounds.height - rectHeight) / 2,
                          width: rectWidth,
                          height: rectHeight)
        let len: CGFloat = 34
        let path = UIBezierPath()
        let corners: [(CGPoint, Bool, Bool)] = [
            (CGPoint(x: rect.minX, y: rect.minY), true, true),
            (CGPoint(x: rect.maxX, y: rect.minY), false, true),
            (CGPoint(x: rect.minX, y: rect.maxY), true, false),
            (CGPoint(x: rect.maxX, y: rect.maxY), false, false)
        ]
        for (p, horRight, verDown) in corners {
            path.move(to: p)
            path.addLine(to: CGPoint(x: p.x + (horRight ? len : -len), y: p.y))
            path.move(to: p)
            path.addLine(to: CGPoint(x: p.x, y: p.y + (verDown ? len : -len)))
        }
        crosshairLayer.path = path.cgPath
    }

    // MARK: - 日志

    private func appendLog(_ text: String) {
        logLines.append(text)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        logView.text = logLines.joined(separator: "\n")
        let bottom = NSRange(location: (logView.text as NSString).length - 1, length: 1)
        if bottom.location != NSNotFound {
            logView.scrollRangeToVisible(bottom)
        }
    }

    // MARK: - 相机

    private func configureCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { return }
                self.session.addInput(input)

                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard self.session.canAddOutput(output) else { return }
                self.session.addOutput(output)

                self.session.sessionPreset = .hd1920x1080

                if device.isFocusModeSupported(.continuousAutoFocus) {
                    try? device.lockForConfiguration()
                    device.focusMode = .continuousAutoFocus
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    // 光学/数字变焦：条码每格平均到的像素成倍增加，是提升命中率最直接的一招
                    let want: CGFloat = 1.6
                    if device.maxAvailableVideoZoomFactor >= want {
                        device.videoZoomFactor = want
                    }
                    device.unlockForConfiguration()
                }
            } catch {
                DispatchQueue.main.async { self.appendLog("相机配置失败: \(error.localizedDescription)") }
            }
        }
    }

    private func showPermissionHint() {
        statusLabel.text = "请在 设置 → 隐私与安全性 → 相机 中允许本 App 使用相机"
    }

    private func start() {
        isRunning = true
        frameCount = 0
        fpsMark = Date()
        inflight = 0
        sessionQueue.async { [weak self] in self?.session.startRunning() }
        toggleButton.setTitle("停止接收", for: .normal)
        statusLabel.text = "让彩色条码完整落在绿色方框内（约 25–50cm，可退远一点）"

        // 3 秒后检查相机是否真的在出帧
        frameCheckTimer?.invalidate()
        let t = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.frameCount > 0 {
                    if let d = self.decoder, d.isReady {
                        self.appendLog("相机帧已送达 \(self.frameCount) 帧")
                    } else {
                        self.appendLog("相机帧已送达 \(self.frameCount) 帧（引擎未就绪，暂未解码）")
                    }
                } else {
                    self.appendLog("警告: 相机无帧输出")
                }
            }
        }
        frameCheckTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stop() {
        isRunning = false
        frameQueue.async { [weak self] in self?.inflight = 0 }
        frameCheckTimer?.invalidate()
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
        toggleButton.setTitle("开始接收", for: .normal)
    }

    @objc private func toggle(_ sender: Any) {
        if isRunning { stop() } else { start() }
    }

    // MARK: - 帧处理

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunning, inflight < maxInflight,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let rgba = Self.convertToRgba(pixelBuffer: pixelBuffer) else { return }

        if !didLogFormat {
            didLogFormat = true
            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let srcW = CVPixelBufferGetWidth(pixelBuffer)
            let srcH = CVPixelBufferGetHeight(pixelBuffer)
            let outW = rgba.width
            let outH = rgba.height
            DispatchQueue.main.async { [weak self] in
                self?.appendLog("像素格式: \(fmt) (BGRA=1111970369) 源\(srcW)x\(srcH) → 送入\(outW)x\(outH)")
                let chunks = (rgba.data.count + CimbarDecoder.chunkBytes - 1) / CimbarDecoder.chunkBytes
                self?.appendLog("分片投递: 每帧 \(chunks) 段 × 0.76 MB（旧版一次性注入 6.2 MB）")
            }
        }
        if frameCount % 60 == 0 {
            let mean = rgba.mean
            let srcMean = rgba.srcMean
            DispatchQueue.main.async { [weak self] in
                self?.appendLog("帧\(self?.frameCount ?? 0) 亮度 源\(srcMean)/输出\(mean)")
            }
        }

        inflight += 1
        frameCount += 1

        // 每 30 帧报一次真实帧率与本进程物理内存（用来看分片投递有没有把峰值压下来）
        if frameCount % 30 == 0 {
            let elapsed = Date().timeIntervalSince(fpsMark)
            fpsMark = Date()
            let fps = elapsed > 0 ? Double(30) / elapsed : 0
            let fpsText = String(format: "%.1f", fps)
            let mb = Self.residentMB()
            let memText = mb > 0 ? String(format: " | 内存 %.1f MB", mb) : ""
            let drops = decoder?.droppedFrames ?? 0
            DispatchQueue.main.async { [weak self] in
                self?.appendLog("帧率 \(fpsText) fps\(memText) | 丢帧 \(drops)")
            }
        }

        if frameCount % 16 == 0, let img = Self.imageFromRgba(rgba.data, rgba.width, rgba.height) {
            DispatchQueue.main.async { [weak self] in self?.enginePreview.image = img }
        }
        decoder?.feedFrame(data: rgba.data, width: rgba.width, height: rgba.height) { [weak self] in
            guard let self = self else { return }
            self.frameQueue.async { self.inflight -= 1 }
        }
    }

    /// 本进程物理内存（MB）。WKWebView 的 WebContent 是独立进程读不到，
    /// 这里量的是我们自己持有的 Data / 字符串，正好能证明“大字符串没了”。
    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), p, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : -1
    }

    /// 把送进引擎的 RGBA 帧转成 UIImage，用于实时预览（诊断用）
    private static func imageFromRgba(_ data: Data, _ w: Int, _ h: Int) -> UIImage? {
        guard w > 0, h > 0,
              let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// BGRA → 画面正中正方形（边长=短边）→ 原生像素换通道成 RGBA，不缩放
    /// 注意：vImagePermuteChannels_ARGB8888 的参数顺序是 (src, dest, permuteMap, flags)，
    /// 之前写成 (dest, src) 会让目标缓冲永远不被写入 → 全黑帧。这里改为纯字节交换，彻底消除歧义。
    private static func convertToRgba(pixelBuffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int, mean: UInt64, srcMean: UInt64)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let srcRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard srcW > 1, srcH > 1, srcRow > 0 else { return nil }

        // 取画面正中的正方形（边长 = 短边）：横向用满全宽，绝不切掉条码角标；
        // 原生像素直送、不缩放，条码每格的像素数达到 1080p 采集的上限。
        let side = min(srcW, srcH)
        let cx = (srcW - side) / 2
        let cy = (srcH - side) / 2
        let cw = side
        let ch = side

        let srcPtr = base.assumingMemoryBound(to: UInt8.self)

        // 源亮度（采样裁剪区）：区分“相机给的就是黑帧”还是“转换环节出错”
        var srcSum: UInt64 = 0
        var srcN: UInt64 = 0
        var sy = 0
        while sy < ch {
            var sx = 0
            while sx < cw {
                let off = (cy + sy) * srcRow + (cx + sx) * 4
                srcSum += UInt64(srcPtr[off]) + UInt64(srcPtr[off + 1]) + UInt64(srcPtr[off + 2])
                srcN += 3
                sx += 16
            }
            sy += 8
        }
        let srcMean: UInt64 = srcN > 0 ? srcSum / srcN : 0

        // 只有超过 1080 才缩小（1080p 采集时等于不缩放）
        let maxSide = 1080
        let longest = max(cw, ch)
        let shrink = longest > maxSide ? Double(maxSide) / Double(longest) : 1.0
        let tw = max(1, Int((Double(cw) * shrink).rounded()))
        let th = max(1, Int((Double(ch) * shrink).rounded()))
        let dstRow = tw * 4
        let count = tw * th * 4

        let outPtr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        defer { outPtr.deallocate() }

        let cropPtr = base.advanced(by: cy * srcRow + cx * 4)

        if tw == cw && th == ch {
            if srcRow == dstRow {
                outPtr.copyMemory(from: cropPtr, byteCount: count)
            } else {
                var row = 0
                while row < ch {
                    outPtr.advanced(by: row * dstRow)
                        .copyMemory(from: cropPtr.advanced(by: row * srcRow), byteCount: dstRow)
                    row += 1
                }
            }
        } else {
            var src = vImage_Buffer(data: cropPtr,
                                    height: vImagePixelCount(ch),
                                    width: vImagePixelCount(cw),
                                    rowBytes: srcRow)
            var dst = vImage_Buffer(data: outPtr,
                                    height: vImagePixelCount(th),
                                    width: vImagePixelCount(tw),
                                    rowBytes: dstRow)
            guard vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return nil }
        }

        // BGRA → RGBA（纯字节交换，A 置 255）
        let px = outPtr.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < count {
            let b = px[i]
            px[i] = px[i + 2]
            px[i + 2] = b
            px[i + 3] = 255
            i += 4
        }

        let outData = Data(bytes: outPtr, count: count)

        // 输出亮度均值（采样）
        var sum: UInt64 = 0
        var n: UInt64 = 0
        var k = 0
        while k < count {
            sum += UInt64(outData[k])
            n += 1
            k += 64
        }
        let mean: UInt64 = n > 0 ? sum / n : 0

        return (outData, tw, th, mean, srcMean)
    }

    // MARK: - UI

    private func setupUI() {
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.text = "打开后请点击“开始接收”"

        progressView.progressTintColor = .systemGreen

        progressLabel.textColor = .white
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        progressLabel.textAlignment = .center
        progressLabel.text = "尚未开始"

        logView.isEditable = false
        logView.isScrollEnabled = true
        logView.backgroundColor = UIColor(white: 0, alpha: 0.35)
        logView.textColor = UIColor(white: 1, alpha: 0.9)
        logView.font = .systemFont(ofSize: 12)
        logView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        logView.layer.cornerRadius = 10
        logView.text = "解码引擎加载中…"

        enginePreview.contentMode = .scaleAspectFill
        enginePreview.clipsToBounds = true
        enginePreview.layer.cornerRadius = 8
        enginePreview.layer.borderWidth = 1
        enginePreview.layer.borderColor = UIColor.systemGreen.cgColor
        enginePreview.backgroundColor = UIColor(white: 0.2, alpha: 0.6)

        crosshairView.isUserInteractionEnabled = false
        crosshairView.backgroundColor = .clear
        crosshairLayer.strokeColor = UIColor.systemGreen.cgColor
        crosshairLayer.lineWidth = 3
        crosshairLayer.fillColor = UIColor.clear.cgColor
        crosshairView.layer.addSublayer(crosshairLayer)

        toggleButton.setTitle("开始接收", for: .normal)
        toggleButton.setTitleColor(.black, for: .normal)
        toggleButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        toggleButton.backgroundColor = .white
        toggleButton.layer.cornerRadius = 22
        toggleButton.addTarget(self, action: #selector(toggle(_:)), for: .touchUpInside)

        [statusLabel, progressView, progressLabel, logView, enginePreview, crosshairView, toggleButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            crosshairView.topAnchor.constraint(equalTo: view.topAnchor),
            crosshairView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            crosshairView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            crosshairView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -152),

            enginePreview.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            enginePreview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            enginePreview.widthAnchor.constraint(equalToConstant: 132),
            enginePreview.heightAnchor.constraint(equalToConstant: 74),

            progressView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            progressLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 6),
            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            logView.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 10),
            logView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            logView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            logView.heightAnchor.constraint(equalToConstant: 170),

            toggleButton.topAnchor.constraint(equalTo: logView.bottomAnchor, constant: 14),
            toggleButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 180),
            toggleButton.heightAnchor.constraint(equalToConstant: 44),
            toggleButton.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])
    }
}
