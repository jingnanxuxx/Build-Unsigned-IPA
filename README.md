# Cimbar 传文件（CimbarFileCopy）

原生 iOS 接收端：用相机扫描电脑屏幕上的 cimbar 彩色条码，接收从电脑发送过来的文件。
**纯原生相机采集**，解码在隐藏 WKWebView 中完成（引擎只做计算、不渲染相机画面），
绕开 iOS 15.0.2 上 WKWebView 相机黑屏的 WebKit bug。

> 本项目由你手头的 CameraFileCopy.ipa（基于 cimbar 的网页壳）重写而来：
> 网页壳在 iOS 15.0.2 上相机黑屏（原包要求 iOS 15.4+，见其 README），
> 此版本把「相机取帧」改为原生 AVFoundation，解码逻辑与网页端 1:1 对应。

## 目录结构

```
CimbarFileCopy/
├── .github/workflows/build-ipa.yml   ← GitHub Actions 云端免签名构建
├── project.yml                       ← XcodeGen 工程配置（含 AppIcon 配置）
├── README.md
└── CimbarFileCopy/
    ├── AppDelegate.swift             ← 入口
    ├── ViewController.swift          ← 相机采集/预览/日志/进度界面（AVFoundation + Accelerate）
    ├── CimbarDecoder.swift           ← WKWebView 解码引擎宿主（loadHTMLString 内嵌引擎 + JS 探针）
    ├── DecoderEmbed.swift            ← 解码引擎 HTML 的 base64 内嵌（3.5MB，构建唯一来源）
    ├── Assets.xcassets/              ← 应用图标（AppIcon.appiconset）
    └── Resources/                    ← 引擎源文件备份（已内嵌进 DecoderEmbed.swift，不参与打包）
```

## 一、上传 GitHub（重要：内容放根目录，不要嵌套）

本仓库已按「文件放根目录」设计，**不要把整个 CimbarFileCopy 文件夹拖进去**，否则 GitHub
只认根目录的 `.github/workflows/`，Actions 不会触发。

正确做法（二选一）：

**方式 A（推荐，一次拖完）**：进入仓库 → `Add file` → `Upload files` →
打开本机 `CimbarFileCopy` 文件夹，选中里面的 **全部内容**（`.github`、`CimbarFileCopy`、
`project.yml`、`README.md`）拖进网页 → Commit。确保仓库根目录能看到 `project.yml`
和 `.github/workflows/build-ipa.yml`。

**方式 B（逐个建文件）**：`Add file` → `Create new file`，文件名字段里直接带斜杠自动建目录，
例如输入 `.github/workflows/build-ipa.yml`。二进制文件（cimbar_js.wasm 1.9MB）建议用方式 A。

## 二、等待构建并下载

1. 上传后 GitHub 自动触发 Actions（工作流名 `Build Unsigned IPA`）。
   也可手动触发：仓库 `Actions` 页 → 左侧选 `Build Unsigned IPA` → `Run workflow`。
2. 构建约 3–6 分钟，完成后在 Actions 运行页底部 `Artifacts` 处下载
   `CimbarFileCopy-unsigned-ipa`（一个 zip）。
3. 解压得到 `CimbarFileCopy.ipa`。

## 三、安装（巨魔）

- 把 `CimbarFileCopy.ipa` 通过任意方式（爱思助手、Safari 下载、隔空投送等）传到 iPhone；
- 用 TrollStore（巨魔）打开 → 自动安装；免签名，重启后依然有效。
- 与旧 App `CameraFileCopy` 是**两个不同的 App**（bundle id 不同），可共存；旧的可删可不删。
- 覆盖安装新版时，TrollStore 会询问替换，点确认即可，App 数据不受影响。

## 四、使用（接收端）

1. 电脑浏览器打开 cimbar 发送端（例如 <https://cimbar.org>，或原 IPA 附带发送页 send.html），
   选择文件开始发送，屏幕会显示彩色条码动画；
2. iPhone 打开「Cimbar 传文件」→ 点「开始接收」→ 首次会请求相机权限（请允许）；
3. 手机对准屏幕上的条码，保持 15–40cm、让整个条码区域在画面内；
4. 底部进度条显示接收进度，接收完成后弹出系统分享面板 → 选「存储到‘文件’」即可保存。

## 技术说明

- 相机：AVCaptureSession 720p → BGRA → vImage 缩放（短边 360）+ 通道置换为 RGBA；
- 解码：隐藏 WKWebView 加载 decoder.html + cimbar_js 引擎，每帧 base64 传入，
  模式自动轮询（Bu/B/Bm/4C），与网页端 recv 逻辑一致；
- 引擎加载：decoder.html（自包含：wasm 与 cimbar_js 全内联）以 **base64 内嵌进
  DecoderEmbed.swift**，运行时解码后由 `loadHTMLString` 直接加载——**不依赖 Bundle 资源打包**，
  从根源杜绝"资源未进 App 包导致引擎不启动"；
  App 内置 2 秒 JS 探针（检查 CimbarBridge/Module 是否真实执行，规避空页面误报）与相机帧计数，
  日志按阶段打印：内嵌引擎已解出 → 页面已加载 → wasm 已解码 → 引擎页面已执行(探针) →
  引擎就绪 → 解码引擎就绪 → 相机帧已送达 N 帧，真机遇到问题可据此精确定位到具体环节；
- 完成：fountain 汇流 → 文件名/大小 → zstd 分块解压 → 系统分享面板。

## 许可

解码引擎为开源项目 [sz3/libcimbar](https://github.com/sz3/libcimbar) 的 cimbar_js
构建产物（随原 CameraFileCopy.ipa 分发，此处内嵌使用）。分发或商用前请核对 libcimbar
的开源许可证与原作者条款。

## 已知边界

- iOS App 无法在 Windows 上运行/验证：首次真机验证请在 iPhone（iOS 15.0.2）上进行；
- 解码正确性、帧率、对焦距离等以真机为准，如有问题（收不到、卡顿）可反馈调整
  （分辨率/帧率/模式顺序等参数都在 ViewController.swift 与 decoder.html 中）。
