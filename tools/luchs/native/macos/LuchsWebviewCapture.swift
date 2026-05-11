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

        startInputReader()
        view.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        if frameCount > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.loaded == false {
                    fail("timed out loading \(self?.fileURL.path ?? "html")")
                }
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

    private func startInputReader() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while let line = readLine() {
                guard !line.isEmpty else { continue }
                DispatchQueue.main.async { [weak self] in
                    self?.handleInputLine(line)
                }
            }
        }
    }

    private func handleInputLine(_ line: String) {
        guard let webView else { return }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let type = message["type"] as? String,
              !type.isEmpty else {
            return
        }
        let jsonData = (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"
        let script = """
        (() => {
          const event = \(json);
          const x = Number.isFinite(event.x) ? event.x : 0;
          const y = Number.isFinite(event.y) ? event.y : 0;
          const target = document.elementFromPoint(x, y) || document.body || document.documentElement;
          const common = { bubbles: true, cancelable: true, view: window };
          const focusedTarget = () => {
            const active = document.activeElement;
            return active && active !== document.body ? active : document;
          };
          const ensureSyntheticCaret = () => {
            if (window.__luchsEnsureCaret) {
              window.__luchsEnsureCaret();
              return;
            }
            window.__luchsEnsureCaret = () => {
              if (window.__luchsCaretInstalled) return;
              window.__luchsCaretInstalled = true;
              const style = document.createElement("style");
              style.textContent = `
                #luchs-synthetic-caret {
                  position: fixed;
                  display: none;
                  width: 2px;
                  background: #f6c343;
                  pointer-events: none;
                  z-index: 2147483647;
                  animation: luchs-caret-blink 1s steps(1, end) infinite;
                }
                @keyframes luchs-caret-blink {
                  0%, 49% { opacity: 1; }
                  50%, 100% { opacity: 0; }
                }
              `;
              document.head.appendChild(style);

              const caret = document.createElement("div");
              caret.id = "luchs-synthetic-caret";
              document.documentElement.appendChild(caret);

              const textLikeInput = (element) => {
                if (element instanceof HTMLTextAreaElement) return true;
                if (!(element instanceof HTMLInputElement)) return false;
                const type = (element.type || "text").toLowerCase();
                return ["text", "search", "url", "tel", "email", "password"].includes(type);
              };
              const numericStyle = (computed, name) => {
                const value = Number.parseFloat(computed[name]);
                return Number.isFinite(value) ? value : 0;
              };
              const update = () => {
                const active = document.activeElement;
                if (!active || !textLikeInput(active) || active.disabled || active.readOnly) {
                  caret.style.display = "none";
                  return;
                }
                const rect = active.getBoundingClientRect();
                if (rect.width <= 0 || rect.height <= 0) {
                  caret.style.display = "none";
                  return;
                }
                const computed = getComputedStyle(active);
                const canvas = window.__luchsCaretCanvas || (window.__luchsCaretCanvas = document.createElement("canvas"));
                const context = canvas.getContext("2d");
                context.font = computed.font || `${computed.fontSize} ${computed.fontFamily}`;

                const selectionStart = typeof active.selectionStart === "number" ? active.selectionStart : active.value.length;
                const prefix = active.value.slice(0, selectionStart);
                const borderLeft = numericStyle(computed, "borderLeftWidth");
                const borderRight = numericStyle(computed, "borderRightWidth");
                const borderTop = numericStyle(computed, "borderTopWidth");
                const borderBottom = numericStyle(computed, "borderBottomWidth");
                const paddingLeft = numericStyle(computed, "paddingLeft");
                const paddingTop = numericStyle(computed, "paddingTop");
                const paddingBottom = numericStyle(computed, "paddingBottom");
                const fontSize = numericStyle(computed, "fontSize") || 16;
                const lineHeightValue = Number.parseFloat(computed.lineHeight);
                const lineHeight = Number.isFinite(lineHeightValue) ? lineHeightValue : fontSize * 1.2;
                const contentHeight = Math.max(1, rect.height - borderTop - borderBottom - paddingTop - paddingBottom);
                const caretHeight = Math.max(8, Math.min(lineHeight, contentHeight));
                const measured = context.measureText(prefix).width;
                const minimumX = rect.left + borderLeft + paddingLeft;
                const maximumX = Math.max(minimumX, rect.right - borderRight - 2);
                const x = Math.min(maximumX, Math.max(minimumX, minimumX + measured - active.scrollLeft));
                const y = active instanceof HTMLTextAreaElement
                  ? rect.top + borderTop + paddingTop - active.scrollTop
                  : rect.top + borderTop + paddingTop + Math.max(0, (contentHeight - caretHeight) / 2);

                caret.style.display = "block";
                caret.style.left = `${Math.round(x)}px`;
                caret.style.top = `${Math.round(y)}px`;
                caret.style.height = `${Math.round(caretHeight)}px`;
              };
              window.__luchsUpdateCaret = update;
              for (const name of ["focusin", "focusout", "input", "keydown", "keyup", "mousedown", "mouseup"]) {
                document.addEventListener(name, update, true);
              }
              document.addEventListener("selectionchange", update, true);
              window.addEventListener("scroll", update, true);
              window.addEventListener("resize", update, true);
              update();
            };
            window.__luchsEnsureCaret();
          };
          ensureSyntheticCaret();
          const keyName = (keyCode) => {
            if (keyCode === 8) return "Backspace";
            if (keyCode === 9) return "Tab";
            if (keyCode === 13) return "Enter";
            if (keyCode === 27) return "Escape";
            if (keyCode === 127) return "Delete";
            if (keyCode === 1073741904) return "ArrowLeft";
            if (keyCode === 1073741903) return "ArrowRight";
            if (keyCode === 1073741906) return "ArrowUp";
            if (keyCode === 1073741905) return "ArrowDown";
            if (keyCode === 1073741898) return "Home";
            if (keyCode === 1073741901) return "End";
            if (keyCode >= 32 && keyCode <= 126) return String.fromCharCode(keyCode);
            return "";
          };
          const editableValueControl = (element) => {
            if (!element || element.disabled || element.readOnly) return false;
            if (element instanceof HTMLTextAreaElement) return true;
            if (!(element instanceof HTMLInputElement)) return false;
            const type = (element.type || "text").toLowerCase();
            return ["text", "search", "url", "tel", "email", "password"].includes(type);
          };
          const clampSelection = (active, value) => Math.max(0, Math.min(active.value.length, value));
          const setCursor = (active, value) => {
            if (!active.setSelectionRange) return;
            const cursor = clampSelection(active, value);
            active.setSelectionRange(cursor, cursor);
            if (window.__luchsUpdateCaret) window.__luchsUpdateCaret();
          };
          const editInput = (active, inputType, start, end, replacement) => {
            replacement = String(replacement ?? "");
            const before = new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType, data: replacement || null });
            if (!active.dispatchEvent(before)) return;
            active.value = active.value.slice(0, start) + replacement + active.value.slice(end);
            if (active.setSelectionRange) {
              const cursor = start + replacement.length;
              active.setSelectionRange(cursor, cursor);
            }
            active.dispatchEvent(new InputEvent("input", { bubbles: true, inputType, data: replacement || null }));
            if (window.__luchsUpdateCaret) window.__luchsUpdateCaret();
          };
          const applyKeyDefault = (keyCode) => {
            const active = document.activeElement;
            if (!editableValueControl(active)) return;
            const start = active.selectionStart ?? active.value.length;
            const end = active.selectionEnd ?? start;
            if (keyCode === 8) {
              if (start !== end) {
                editInput(active, "deleteContentBackward", start, end, "");
              } else if (start > 0) {
                editInput(active, "deleteContentBackward", start - 1, start, "");
              }
            } else if (keyCode === 127) {
              if (start !== end) {
                editInput(active, "deleteContentForward", start, end, "");
              } else if (start < active.value.length) {
                editInput(active, "deleteContentForward", start, start + 1, "");
              }
            } else if (keyCode === 13 && active instanceof HTMLTextAreaElement) {
              editInput(active, "insertLineBreak", start, end, String.fromCharCode(10));
            } else if (keyCode === 1073741904 || keyCode === 1073741906) {
              setCursor(active, start !== end ? start : start - 1);
            } else if (keyCode === 1073741903 || keyCode === 1073741905) {
              setCursor(active, start !== end ? end : end + 1);
            } else if (keyCode === 1073741898) {
              setCursor(active, 0);
            } else if (keyCode === 1073741901) {
              setCursor(active, active.value.length);
            }
          };
          const scrollableAt = (start, deltaX, deltaY) => {
            let node = start;
            while (node && node !== document.documentElement) {
              if (node instanceof Element) {
                const style = getComputedStyle(node);
                const canScrollY = Math.abs(deltaY) > 0 && /(auto|scroll|overlay)/.test(style.overflowY) && node.scrollHeight > node.clientHeight;
                const canScrollX = Math.abs(deltaX) > 0 && /(auto|scroll|overlay)/.test(style.overflowX) && node.scrollWidth > node.clientWidth;
                if (canScrollY || canScrollX) return node;
              }
              node = node.parentElement;
            }
            return document.scrollingElement || document.documentElement;
          };
          const applyWheelDefault = (start, deltaX, deltaY) => {
            const scroller = scrollableAt(start, deltaX, deltaY);
            if (!scroller) return;
            scroller.scrollLeft += deltaX;
            scroller.scrollTop += deltaY;
          };
          if (event.type === "mouse_move") {
            target.dispatchEvent(new MouseEvent("mousemove", { ...common, clientX: x, clientY: y }));
          } else if (event.type === "mouse_down" || event.type === "mouse_up") {
            const button = Math.max(0, Number(event.button || 1) - 1);
            const name = event.type === "mouse_down" ? "mousedown" : "mouseup";
            if (event.type === "mouse_down" && target.focus) { target.focus(); }
            target.dispatchEvent(new MouseEvent(name, { ...common, clientX: x, clientY: y, button }));
            if (event.type === "mouse_up") {
              target.dispatchEvent(new MouseEvent("click", { ...common, clientX: x, clientY: y, button }));
            }
          } else if (event.type === "wheel") {
            const deltaX = -Number(event.dx || 0) * 40;
            const deltaY = -Number(event.dy || 0) * 40;
            const wheel = new WheelEvent("wheel", { ...common, clientX: x, clientY: y, deltaX, deltaY });
            if (target.dispatchEvent(wheel)) {
              applyWheelDefault(target, deltaX, deltaY);
            }
          } else if (event.type === "key_down" || event.type === "key_up") {
            const name = event.type === "key_down" ? "keydown" : "keyup";
            const keyCode = Number(event.keycode || 0);
            const keyboard = new KeyboardEvent(name, { ...common, key: keyName(keyCode), keyCode, which: keyCode, repeat: !!event.repeat });
            if (focusedTarget().dispatchEvent(keyboard) && event.type === "key_down") {
              applyKeyDefault(keyCode);
            }
          } else if (event.type === "text") {
            const text = String(event.text || "");
            const active = document.activeElement;
            if (editableValueControl(active)) {
              const start = active.selectionStart ?? active.value.length;
              const end = active.selectionEnd ?? start;
              editInput(active, "insertText", start, end, text);
            } else {
              const before = new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: "insertText", data: text });
              if (!document.dispatchEvent(before)) return;
              document.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
            }
          }
          if (window.__luchsUpdateCaret) window.__luchsUpdateCaret();
        })()
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
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
          if (window.__luchsUpdateCaret) { window.__luchsUpdateCaret(); }
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
        if frameCount > 0 && emittedFrames >= frameCount {
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
        guard width > 0 && height > 0 && frameCount >= 0 && fps > 0 else {
            fail("width, height, and fps must be positive; frame_count must be zero or positive")
        }

        let url = URL(fileURLWithPath: args[1])
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("file not found: \(url.path)")
        }

        let controller = CaptureController(fileURL: url, width: width, height: height, frameCount: frameCount, fps: fps)
        controller.run()
    }
}
