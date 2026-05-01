import Cocoa
import WebKit

private let defaultWidth = 800
private let defaultHeight = 600
private let defaultFrameCount = 1
private let defaultFps = 15

private func fail(_ message: String) -> Never {
    fputs("luchs-webview-capture: \(message)\n", stderr)
    exit(1)
}

private final class CaptureController: NSObject, WKNavigationDelegate {
    private let fileURL: URL
    private let width: Int
    private let height: Int
    private let frameCount: Int
    private let frameInterval: TimeInterval
    private var window: NSWindow?
    private var webView: WKWebView?
    private var loaded = false
    private var emittedFrames = 0

    init(fileURL: URL, width: Int, height: Int, frameCount: Int, fps: Int) {
        self.fileURL = fileURL
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.frameInterval = 1.0 / Double(fps)
    }

    func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let rect = NSRect(x: -20000, y: -20000, width: width, height: height)
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: rect, configuration: configuration)
        view.navigationDelegate = self

        let captureWindow = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        captureWindow.contentView = view
        captureWindow.orderFront(nil)

        self.webView = view
        self.window = captureWindow

        view.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if self?.loaded == false {
                fail("timed out loading \(self?.fileURL.path ?? "html")")
            }
        }
        NSApplication.shared.run()
        fail("application run loop exited unexpectedly")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.capture(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error.localizedDescription)")
    }

    private func capture(_ webView: WKWebView) {
        let tickMilliseconds = Int(Double(emittedFrames) * frameInterval * 1000.0)
        let script = """
        (() => {
          const tick = \(tickMilliseconds);
          const animations = document.getAnimations ? document.getAnimations({ subtree: true }) : [];
          for (const animation of animations) {
            try {
              const timing = animation.effect && animation.effect.getTiming ? animation.effect.getTiming() : {};
              const duration = Number.isFinite(timing.duration) && timing.duration > 0 ? timing.duration : 1000;
              animation.pause();
              animation.currentTime = tick % duration;
            } catch (_) {}
          }
          document.documentElement.style.setProperty("--luchs-capture-tick", String(tick));
          document.documentElement.style.setProperty("--luchs-capture-scale", String(0.15 + 0.85 * ((tick % 1000) / 1000)));
          if (document.body) { void document.body.offsetWidth; }
          return animations.length;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            self?.snapshot(webView)
        }
    }

    private func snapshot(_ webView: WKWebView) {
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(x: 0, y: 0, width: width, height: height)
        webView.takeSnapshot(with: snapshot) { [weak self] image, error in
            guard let self else { return }
            if let error {
                fail("snapshot failed: \(error.localizedDescription)")
            }
            guard let image else {
                fail("snapshot returned no image")
            }
            self.emit(image)
        }
    }

    private func emit(_ image: NSImage) {
        var proposed = NSRect(x: 0, y: 0, width: width, height: height)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            fail("snapshot has no CGImage")
        }

        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: stride,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                fail("failed to create bitmap context")
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let header = "LUCHS_RAW_FRAME {\"format\":\"rgba8\",\"width\":\(width),\"height\":\(height),\"stride\":\(stride),\"len\":\(pixels.count)}\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        pixels.withUnsafeBufferPointer { buffer in
            FileHandle.standardOutput.write(Data(buffer: buffer))
        }
        emittedFrames += 1
        if emittedFrames >= frameCount {
            NSApplication.shared.terminate(nil)
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) { [weak self] in
            guard let self, let webView = self.webView else { return }
            self.capture(webView)
        }
    }
}

@main
private enum LuchsWebviewCapture {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fail("usage: luchs-webview-capture path/to/fragment.html [width height [frame_count fps]]")
        }
        let width = args.count >= 3 ? (Int(args[2]) ?? defaultWidth) : defaultWidth
        let height = args.count >= 4 ? (Int(args[3]) ?? defaultHeight) : defaultHeight
        let frameCount = args.count >= 5 ? (Int(args[4]) ?? defaultFrameCount) : defaultFrameCount
        let fps = args.count >= 6 ? (Int(args[5]) ?? defaultFps) : defaultFps
        guard width > 0 && height > 0 && frameCount > 0 && fps > 0 else {
            fail("width, height, frame_count, and fps must be positive")
        }

        let url = URL(fileURLWithPath: args[1])
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("file not found: \(url.path)")
        }

        let controller = CaptureController(fileURL: url, width: width, height: height, frameCount: frameCount, fps: fps)
        controller.run()
    }
}
