import UIKit
import AVFoundation
import Accelerate

final class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cimbar.camera.session")
    private let frameQueue = DispatchQueue(label: "cimbar.camera.frames")
    private var decoder: CimbarDecoder?
    private var previewLayer = AVCaptureVideoPreviewLayer()

    private var isRunning = false
    private var framePending = false
    private var frameCount = 0
    private var frameCheckTimer: Timer?

    private var logLines: [String] = []

    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let logView = UITextView()
    private let toggleButton = UIButton(type: .system)

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

                self.session.sessionPreset = .hd1280x720

                if device.isFocusModeSupported(.continuousAutoFocus) {
                    try? device.lockForConfiguration()
                    device.focusMode = .continuousAutoFocus
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
        sessionQueue.async { [weak self] in self?.session.startRunning() }
        toggleButton.setTitle("停止接收", for: .normal)
        statusLabel.text = "对准电脑屏幕上的彩色条码，保持 15–40cm"

        // 3 秒后检查相机是否真的在出帧
        frameCheckTimer?.invalidate()
        let t = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.frameCount > 0 {
                    self.appendLog("相机帧已送达 \(self.frameCount) 帧")
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
        framePending = false
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
        guard isRunning, !framePending,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let rgba = Self.convertToRgba(pixelBuffer: pixelBuffer) else { return }

        framePending = true
        frameCount += 1
        let b64 = rgba.data.base64EncodedString()
        decoder?.feedFrame(base64: b64, width: rgba.width, height: rgba.height) { [weak self] in
            self?.framePending = false
        }
    }

    /// BGRA 像素 → 缩小到短边约 360px 的 RGBA 像素（与网页端 16:9 采集口径一致）
    private static func convertToRgba(pixelBuffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        let shortSide = min(srcW, srcH)
        let scale = 360.0 / Double(shortSide)
        let tw = max(1, Int((Double(srcW) * scale).rounded()))
        let th = max(1, Int((Double(srcH) * scale).rounded()))
        let dstRow = tw * 4

        var src = vImage_Buffer(data: base,
                                height: vImagePixelCount(srcH),
                                width: vImagePixelCount(srcW),
                                rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))

        var scaled = [UInt8](repeating: 0, count: tw * th * 4)
        var scaleBuf = vImage_Buffer(data: &scaled,
                                     height: vImagePixelCount(th),
                                     width: vImagePixelCount(tw),
                                     rowBytes: dstRow)
        let scaleErr = vImageScale_ARGB8888(&src, &scaleBuf, nil, vImage_Flags(kvImageHighQualityResampling))
        guard scaleErr == kvImageNoError else { return nil }

        var out = [UInt8](repeating: 0, count: tw * th * 4)
        let permute: [UInt8] = [2, 1, 0, 3]
        var outBuf = vImage_Buffer(data: &out,
                                   height: vImagePixelCount(th),
                                   width: vImagePixelCount(tw),
                                   rowBytes: dstRow)
        let permuteErr = vImagePermuteChannels_ARGB8888(&outBuf, &scaleBuf, permute, vImage_Flags(kvImageNoFlags))
        guard permuteErr == kvImageNoError else { return nil }

        return (Data(out), tw, th)
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

        toggleButton.setTitle("开始接收", for: .normal)
        toggleButton.setTitleColor(.black, for: .normal)
        toggleButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        toggleButton.backgroundColor = .white
        toggleButton.layer.cornerRadius = 22
        toggleButton.addTarget(self, action: #selector(toggle(_:)), for: .touchUpInside)

        [statusLabel, progressView, progressLabel, logView, toggleButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

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
