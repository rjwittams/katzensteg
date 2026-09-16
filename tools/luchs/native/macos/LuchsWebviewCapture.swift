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

// Page console output, page errors and navigations, one line each, in the
// file LUCHS_CONSOLE_LOG names (default /tmp/luchs-console-<pid>.log). The
// helper's stdout carries frames and its stderr is the launcher's, so this
// is the one place a page can be debugged from.
private let consoleLogPath: String = ProcessInfo.processInfo.environment["LUCHS_CONSOLE_LOG"]
    ?? "/tmp/luchs-console-\(getpid()).log"
private let consoleLogHandle: FileHandle? = {
    FileManager.default.createFile(atPath: consoleLogPath, contents: nil)
    return FileHandle(forWritingAtPath: consoleLogPath)
}()
private let consoleLogQueue = DispatchQueue(label: "luchs.console-log")
private let consoleLogStart = Date()

private func debugLog(_ line: String) {
    guard let handle = consoleLogHandle else { return }
    let stamp = String(format: "%8.3f", Date().timeIntervalSince(consoleLogStart))
    let text = "\(stamp) \(line)\n"
    consoleLogQueue.async {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }
}

private let consoleForwarderSource = """
(() => {
  const describe = (value) => {
    if (typeof value === "string") return value;
    if (value instanceof Error) return value.stack || value.message;
    try { return JSON.stringify(value); } catch (_) { return String(value); }
  };
  const post = (level, args) => {
    try {
      const text = args.map(describe).join(" ").slice(0, 4000);
      window.webkit.messageHandlers.luchsConsole.postMessage({ level, text });
    } catch (_) {}
  };
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const original = typeof console[level] === "function" ? console[level].bind(console) : null;
    console[level] = (...args) => { post(level, args); if (original) original(...args); };
  }
  window.addEventListener("error", (e) => post("error", [`${e.message} (${e.filename}:${e.lineno}:${e.colno})`]));
  window.addEventListener("unhandledrejection", (e) => post("error", ["unhandled rejection:", e.reason]));
  // Liveness of the page clock: an offscreen view may never run
  // requestAnimationFrame, and a page that awaits one hangs.
  let frame = false;
  requestAnimationFrame(() => { frame = true; post("debug", ["requestAnimationFrame fired"]); });
  setTimeout(() => post("debug", [`after 2s: visibility ${document.visibilityState}, hasFocus ${document.hasFocus()}, requestAnimationFrame ${frame ? "ran" : "never ran"}`]), 2000);
})();
"""

// A caret for the frame's focused text field. WebKit draws its own only
// while its window is key, which this transparent window never is, so the
// page gets one drawn from the selection; it follows focus, input and
// scrolling in every frame, iframes included.
private let caretScriptSource = """
(() => {
  try {
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
  } catch (error) { console.error("luchs caret script failed:", error && (error.stack || error.message || error)); }
})();
"""

private final class CaptureController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    // A local file, or an http(s) page. The default website data store is
    // persistent for this binary (under ~/Library/WebKit), so a login made in
    // one run is still there in the next.
    private let fileURL: URL
    private var isFile: Bool { fileURL.isFileURL }
    private let width: Int
    private let height: Int
    private let frameCount: Int
    private let frameInterval: TimeInterval
    private var window: NSWindow?
    private var webView: WKWebView?
    // Windows the page opened (OAuth sign-in, target=_blank), newest last.
    // The capture and the input follow the newest one while it is open, so
    // a sign-in popup is what the panel shows and types into; when the page
    // closes it, the main view is back. The popup keeps its opener, so a
    // flow that posts its result back to the opener completes.
    private var popups: [WKWebView] = []
    private var activeView: WKWebView? { popups.last ?? webView }
    private var loaded = false
    private var capturing = false
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
        // Sign-in providers refuse a bare WebKit agent as an embedded view;
        // the Safari tokens make this the browser it effectively is.
        configuration.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"
        configuration.userContentController.addUserScript(
            WKUserScript(source: consoleForwarderSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController.add(self, name: "luchsConsole")
        configuration.userContentController.addUserScript(
            WKUserScript(source: caretScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        debugLog("luchs-webview-capture \(width)x\(height) page \(fileURL.absoluteString)")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        let container = NSView(frame: rect)
        container.addSubview(view)

        let captureWindow = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        captureWindow.contentView = container
        // WebKit treats an off-screen or occluded window as a hidden page:
        // requestAnimationFrame stops, timers slow, and a page that awaits a
        // frame (a sign-in form after submit, say) hangs. So the window is on
        // screen, fully transparent, ignoring the mouse, on every Space and
        // above fullscreen apps, so it is never occluded and never seen. The
        // capture reads the view through takeSnapshot, not the screen.
        captureWindow.alphaValue = 0.0
        captureWindow.ignoresMouseEvents = true
        captureWindow.hasShadow = false
        captureWindow.level = .screenSaver
        captureWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // The primary screen's origin, so that window coordinates are screen
        // coordinates: a scroll event built from a CGEvent carries only those.
        if let screen = NSScreen.screens.first {
            captureWindow.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
        captureWindow.orderFront(nil)

        self.webView = view
        self.window = captureWindow

        startInputReader()
        if isFile {
            view.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: fileURL))
        }
        if frameCount > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.loaded == false {
                    fail("timed out loading \(self?.fileURL.absoluteString ?? "html")")
                }
            }
        }
        NSApplication.shared.run()
        fail("application run loop exited unexpectedly")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let level = body["level"] as? String ?? "log"
        let text = body["text"] as? String ?? ""
        debugLog("console.\(level) \(text)")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        debugLog("navigation start \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("navigation finish \(webView.url?.absoluteString ?? "?")")
        loaded = true
        // One capture chain for the helper's life: a reload lands in it.
        guard !capturing else { return }
        capturing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.capture(webView)
        }
    }

    // window.open and target=_blank get a real second view (without a
    // delegate they return null and a sign-in flow fails on the spot). It
    // takes the panel's full size and sits above the main view; the
    // configuration WebKit hands over keeps the opener link and the data
    // store, so the popup shares the login.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let container = window?.contentView else { return nil }
        let popup = WKWebView(frame: container.bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        container.addSubview(popup)
        popups.append(popup)
        debugLog("popup \(popups.count) opened for \(navigationAction.request.url?.absoluteString ?? "?")")
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let index = popups.firstIndex(of: webView) else { return }
        popups.remove(at: index)
        webView.removeFromSuperview()
        debugLog("popup \(index + 1) closed by the page; \(popups.isEmpty ? "main view" : "popup \(popups.count)") is active")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, error)
    }

    // The first page failing to load ends the helper. Later failures do not:
    // a popup's, or a load cancelled by a redirect or by the page itself
    // (NSURLErrorCancelled), are the page's business and are only logged.
    private func navigationFailed(_ webView: WKWebView, _ error: Error) {
        let cancelled = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
        let view = webView === self.webView ? "main view" : "popup"
        debugLog("navigation failed in \(view): \(error.localizedDescription)")
        if webView === self.webView && !loaded && !cancelled {
            fail("navigation failed: \(error.localizedDescription)")
        }
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
        if traceInput { debugLog("input line \(line)") }
        guard let mainView = self.webView, let webView = activeView else { return }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let type = message["type"] as? String,
              !type.isEmpty else {
            return
        }
        if type == "reload" {
            // The page file changed (luchs --watch). A plain load of the same
            // file URL can be served from WebKit's cache, so bypass it.
            if isFile, let html = try? String(contentsOf: fileURL, encoding: .utf8) {
                mainView.loadHTMLString(html, baseURL: fileURL)
            } else {
                mainView.reloadFromOrigin()
            }
            return
        }
        if nativeInput {
            deliverNative(message, type: type, to: webView)
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
          if (window.__luchsEnsureCaret) window.__luchsEnsureCaret();
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


    // MARK: Native input

    // Input arrives as NSEvents at the web view, so WebKit's own handling
    // does what the JS bridge approximated: hit testing into iframes,
    // focus, text insertion into any editor, shortcuts. LUCHS_INPUT=bridge
    // selects the bridge instead.
    private let nativeInput = ProcessInfo.processInfo.environment["LUCHS_INPUT"] != "bridge"
    private let traceInput = ProcessInfo.processInfo.environment["LUCHS_INPUT_TRACE"] == "1"

    // Straight to the active view's responder methods rather than through
    // the window: with a popup open, the window would hand keys to its
    // first responder, the main view, not the popup.
    private func route(_ event: NSEvent, to view: WKWebView, _ deliver: (NSEvent) -> Void) {
        if traceInput { debugLog("input \(event.type.rawValue) at \(event.locationInWindow) characters \(event.type == .keyDown || event.type == .keyUp ? event.characters ?? "" : "")") }
        deliver(event)
    }
    private var buttonsDown: Set<Int> = []
    private var lastClick: (time: TimeInterval, x: CGFloat, y: CGFloat, count: Int) = (0, 0, 0, 0)
    // A printable key waits for the text event that follows it (the layout's
    // characters, IME output), and is sent as one key event carrying them.
    private var pendingKey: (keycode: Int, mod: Int, isRepeat: Bool)?
    private var modifierFlags: NSEvent.ModifierFlags = []

    private func windowPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: CGFloat(height) - y)
    }

    private func deliverNative(_ message: [String: Any], type: String, to view: WKWebView) {
        guard let window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let x = CGFloat((message["x"] as? NSNumber)?.doubleValue ?? 0)
        let y = CGFloat((message["y"] as? NSNumber)?.doubleValue ?? 0)
        switch type {
        case "mouse_move":
            let kind: NSEvent.EventType = buttonsDown.contains(1) ? .leftMouseDragged
                : buttonsDown.contains(3) ? .rightMouseDragged
                : buttonsDown.isEmpty ? .mouseMoved : .otherMouseDragged
            guard let event = NSEvent.mouseEvent(with: kind, location: windowPoint(x, y), modifierFlags: modifierFlags, timestamp: now, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            route(event, to: view) { event in
                switch kind {
                case .leftMouseDragged: view.mouseDragged(with: event)
                case .rightMouseDragged: view.rightMouseDragged(with: event)
                case .otherMouseDragged: view.otherMouseDragged(with: event)
                default: view.mouseMoved(with: event)
                }
            }
        case "mouse_down", "mouse_up":
            // SDL buttons: 1 left, 2 middle, 3 right.
            let button = (message["button"] as? NSNumber)?.intValue ?? 1
            let down = type == "mouse_down"
            var count = 1
            if down {
                if now - lastClick.time < 0.5 && abs(x - lastClick.x) < 4 && abs(y - lastClick.y) < 4 { count = lastClick.count + 1 }
                lastClick = (now, x, y, count)
                buttonsDown.insert(button)
            } else {
                count = max(1, lastClick.count)
                buttonsDown.remove(button)
            }
            let kind: NSEvent.EventType = switch button {
            case 1: down ? .leftMouseDown : .leftMouseUp
            case 3: down ? .rightMouseDown : .rightMouseUp
            default: down ? .otherMouseDown : .otherMouseUp
            }
            guard let event = NSEvent.mouseEvent(with: kind, location: windowPoint(x, y), modifierFlags: modifierFlags, timestamp: now, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: down ? 1 : 0) else { return }
            route(event, to: view) { event in
                switch kind {
                case .leftMouseDown: view.mouseDown(with: event)
                case .leftMouseUp: view.mouseUp(with: event)
                case .rightMouseDown: view.rightMouseDown(with: event)
                case .rightMouseUp: view.rightMouseUp(with: event)
                case .otherMouseDown: view.otherMouseDown(with: event)
                default: view.otherMouseUp(with: event)
                }
            }
        case "wheel":
            // SDL: y > 0 is a scroll up, x > 0 a scroll right; a Quartz wheel
            // counts up and left as positive. One SDL notch is 40 pixels.
            let dx = (message["dx"] as? NSNumber)?.doubleValue ?? 0
            let dy = (message["dy"] as? NSNumber)?.doubleValue ?? 0
            guard let quartz = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy * 40), wheel2: Int32(-dx * 40), wheel3: 0) else { return }
            // Quartz locations are global with the origin at the primary
            // screen's top left; the window sits at that screen's origin.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? CGFloat(height)
            quartz.location = CGPoint(x: window.frame.minX + x, y: primaryHeight - (window.frame.minY + CGFloat(height) - y))
            guard let event = NSEvent(cgEvent: quartz) else { return }
            route(event, to: view) { event in view.scrollWheel(with: event) }
        case "key_down", "key_up", "text":
            deliverKey(message, type: type, to: view, now: now)
        default:
            break
        }
    }

    private func deliverKey(_ message: [String: Any], type: String, to view: WKWebView, now: TimeInterval) {
        if type == "text" {
            let text = message["text"] as? String ?? ""
            let pending = pendingKey
            pendingKey = nil
            let keycode = pending?.keycode ?? 0
            let base = keyCharacters(keycode, mod: 0)?.characters ?? text
            sendKey(.keyDown, characters: text, ignoringModifiers: base, keyCode: virtualKeyCode(keycode), flags: modifierFlags, isRepeat: pending?.isRepeat ?? false, to: view, now: now)
            return
        }
        let keycode = (message["keycode"] as? NSNumber)?.intValue ?? 0
        let mod = (message["mod"] as? NSNumber)?.intValue ?? 0
        let isRepeat = (message["repeat"] as? Bool) ?? false
        modifierFlags = modifierFlagsFromSdl(mod)
        let shortcut = !modifierFlags.isDisjoint(with: [.control, .option, .command])
        if type == "key_down" {
            guard let chars = keyCharacters(keycode, mod: mod) else { return }
            if isPrintable(keycode) && !shortcut {
                pendingKey = (keycode, mod, isRepeat)
                return
            }
            sendKey(.keyDown, characters: chars.characters, ignoringModifiers: chars.ignoringModifiers, keyCode: virtualKeyCode(keycode), flags: modifierFlags, isRepeat: isRepeat, to: view, now: now)
        } else {
            if let pending = pendingKey, pending.keycode == keycode, let chars = keyCharacters(keycode, mod: pending.mod) {
                // No text followed (text input was off): send the key as is.
                pendingKey = nil
                sendKey(.keyDown, characters: chars.characters, ignoringModifiers: chars.ignoringModifiers, keyCode: virtualKeyCode(keycode), flags: modifierFlags, isRepeat: pending.isRepeat, to: view, now: now)
            }
            guard let chars = keyCharacters(keycode, mod: mod) else { return }
            sendKey(.keyUp, characters: chars.characters, ignoringModifiers: chars.ignoringModifiers, keyCode: virtualKeyCode(keycode), flags: modifierFlags, isRepeat: false, to: view, now: now)
        }
    }

    private func sendKey(_ kind: NSEvent.EventType, characters: String, ignoringModifiers: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool, to view: WKWebView, now: TimeInterval) {
        guard let window else { return }
        guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: flags, timestamp: now, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers, isARepeat: isRepeat, keyCode: keyCode) else { return }
        route(event, to: view) { event in
            if kind == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
    }

    private func isPrintable(_ keycode: Int) -> Bool { keycode >= 32 && keycode <= 126 }

    private func modifierFlagsFromSdl(_ mod: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mod & 0x3 != 0 { flags.insert(.shift) }
        if mod & 0xC0 != 0 { flags.insert(.control) }
        if mod & 0x300 != 0 { flags.insert(.option) }
        if mod & 0xC00 != 0 { flags.insert(.command) }
        if mod & 0x2000 != 0 { flags.insert(.capsLock) }
        return flags
    }

    // The characters a key event carries: for a printable SDL keycode the
    // US-layout character (shifted when shift is down, the control character
    // under control); for a function key the Cocoa function-key code point.
    private func keyCharacters(_ keycode: Int, mod: Int) -> (characters: String, ignoringModifiers: String)? {
        if isPrintable(keycode) {
            let base = String(UnicodeScalar(UInt8(keycode)))
            var shown = base
            if mod & 0x3 != 0 {
                let shifted: [String: String] = ["`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?"]
                shown = shifted[base] ?? base.uppercased()
            }
            if mod & 0xC0 != 0, let scalar = base.unicodeScalars.first, scalar.value >= 0x40 && scalar.value <= 0x7F {
                shown = String(UnicodeScalar(UInt8(scalar.value & 0x1F)))
            }
            return (shown, base)
        }
        let function: [Int: String] = [
            13: "\r", 27: "\u{1B}", 8: "\u{7F}", 9: "\t", 127: "\u{F728}",
            1073741912: "\r",
            1073741906: "\u{F700}", 1073741905: "\u{F701}", 1073741904: "\u{F702}", 1073741903: "\u{F703}",
            1073741898: "\u{F729}", 1073741901: "\u{F72B}", 1073741899: "\u{F72C}", 1073741902: "\u{F72D}",
            1073741897: "\u{F727}",
        ]
        if let text = function[keycode] { return (text, text) }
        if keycode >= 1073741882 && keycode <= 1073741893 {
            let text = String(UnicodeScalar(UInt32(0xF704 + keycode - 1073741882))!)
            return (text, text)
        }
        return nil
    }

    private func virtualKeyCode(_ keycode: Int) -> UInt16 {
        let table: [Int: UInt16] = [
            0x61: 0, 0x73: 1, 0x64: 2, 0x66: 3, 0x68: 4, 0x67: 5, 0x7A: 6, 0x78: 7, 0x63: 8, 0x76: 9, 0x62: 11,
            0x71: 12, 0x77: 13, 0x65: 14, 0x72: 15, 0x79: 16, 0x74: 17, 0x31: 18, 0x32: 19, 0x33: 20, 0x34: 21,
            0x36: 22, 0x35: 23, 0x3D: 24, 0x39: 25, 0x37: 26, 0x2D: 27, 0x38: 28, 0x30: 29, 0x5D: 30, 0x6F: 31,
            0x75: 32, 0x5B: 33, 0x69: 34, 0x70: 35, 0x6C: 37, 0x6A: 38, 0x27: 39, 0x6B: 40, 0x3B: 41, 0x5C: 42,
            0x2C: 43, 0x2F: 44, 0x6E: 45, 0x6D: 46, 0x2E: 47, 0x60: 50, 0x20: 49,
            13: 36, 9: 48, 8: 51, 27: 53, 127: 117, 1073741912: 76,
            1073741898: 115, 1073741899: 116, 1073741901: 119, 1073741902: 121,
            1073741904: 123, 1073741903: 124, 1073741905: 125, 1073741906: 126,
            1073741882: 122, 1073741883: 120, 1073741884: 99, 1073741885: 118, 1073741886: 96, 1073741887: 97,
            1073741888: 98, 1073741889: 100, 1073741890: 101, 1073741891: 109, 1073741892: 103, 1073741893: 111,
        ]
        return table[keycode] ?? 0
    }

    private func capture(_ webView: WKWebView) {
        let webView = activeView ?? webView
        let tickMilliseconds = Int(Double(emittedFrames) * frameInterval * 1000.0)
        let script = """
        (() => {
          const tick = \(tickMilliseconds);
          // The window is on screen (transparent), so the page's own clock
          // runs its animations, transitions and requestAnimationFrame. The
          // capture tick is exposed for pages that animate off it instead.
          document.documentElement.style.setProperty("--luchs-capture-tick", String(tick));
          document.documentElement.style.setProperty("--luchs-capture-scale", String(0.15 + 0.85 * ((tick % 1000) / 1000)));
          if (window.__luchsUpdateCaret) { window.__luchsUpdateCaret(); }
          if (document.body) { void document.body.offsetWidth; }
          return 0;
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
        // Pixels are emitted as RGBA bytes with premultiplied alpha. The Zig
        // consumer currently treats them as straight RGBA; for fully opaque
        // pages this is invisible, but pages with CSS transparency will read
        // slightly darker than expected. Switch this to non-premultiplied
        // (`.last`) if accurate alpha is needed downstream.
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

        let page = args[1]
        let url: URL
        if page.hasPrefix("http://") || page.hasPrefix("https://") {
            guard let remote = URL(string: page), remote.host != nil else {
                fail("not a URL: \(page)")
            }
            url = remote
        } else {
            url = URL(fileURLWithPath: page)
            guard FileManager.default.fileExists(atPath: url.path) else {
                fail("file not found: \(url.path)")
            }
        }

        let controller = CaptureController(fileURL: url, width: width, height: height, frameCount: frameCount, fps: fps)
        controller.run()
    }
}
