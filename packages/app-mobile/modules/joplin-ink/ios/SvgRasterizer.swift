import UIKit
import WebKit

// Renders an SVG (e.g. a legacy js-draw drawing) to a bitmap using WebKit, which
// supports everything js-draw can produce (paths, text, embedded images...).
//
// The SVG is loaded through an <img> element, so scripts inside the SVG never
// run. The web view is attached (off-screen) to `host`, because WKWebView only
// renders reliably while it is part of a window.
@MainActor
final class SvgRasterizer: NSObject, WKNavigationDelegate {
  private static let timeoutSeconds: UInt64 = 15

  private var loadContinuation: CheckedContinuation<Void, Error>?
  private var webView: WKWebView?

  func rasterize(svg: String, size: CGSize, scale: CGFloat, host: UIView) async throws -> UIImage {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.suppressesIncrementalRendering = true

    let webView = WKWebView(frame: CGRect(x: -size.width - 100, y: 0, width: size.width, height: size.height), configuration: configuration)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.isUserInteractionEnabled = false
    webView.navigationDelegate = self
    host.insertSubview(webView, at: 0)
    self.webView = webView

    defer {
      webView.navigationDelegate = nil
      webView.removeFromSuperview()
      self.webView = nil
    }

    let svgBase64 = Data(svg.utf8).base64EncodedString()
    let html = """
      <!DOCTYPE html>
      <html><head>
      <meta name="viewport" content="width=\(size.width),initial-scale=1,maximum-scale=1,user-scalable=no">
      <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;}
      img{display:block;width:\(size.width)px;height:\(size.height)px;}</style>
      </head><body><img id="svg" src="data:image/svg+xml;base64,\(svgBase64)"></body></html>
      """

    try await withTimeout(seconds: Self.timeoutSeconds) {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        self.loadContinuation = continuation
        webView.loadHTMLString(html, baseURL: nil)
      }
    }

    // Wait until the image is decoded. Content JavaScript is disabled, but
    // JavaScript evaluated by the app still runs.
    let decoded = try await webView.callAsyncJavaScript(
      """
      const img = document.getElementById('svg');
      try { await img.decode(); } catch (error) { return 'error: ' + error; }
      return img.naturalWidth > 0 ? 'ok' : 'error: empty image';
      """,
      contentWorld: .defaultClient
    )
    if let message = decoded as? String, message != "ok" {
      throw InkError.rasterizationFailed(message)
    }

    // Give WebKit a frame to paint the decoded image
    try await Task.sleep(nanoseconds: 100_000_000)

    let snapshotConfiguration = WKSnapshotConfiguration()
    snapshotConfiguration.rect = CGRect(origin: .zero, size: size)
    snapshotConfiguration.afterScreenUpdates = true
    // snapshotWidth is in points; the result uses the screen scale. Render at
    // the requested scale instead so the result does not depend on the device.
    let screenScale = host.window?.screen.scale ?? UIScreen.main.scale
    snapshotConfiguration.snapshotWidth = NSNumber(value: Double(size.width * scale / screenScale))

    let image = try await webView.takeSnapshot(configuration: snapshotConfiguration)
    return image
  }

  // MARK: - WKNavigationDelegate

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      loadContinuation?.resume()
      loadContinuation = nil
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated {
      loadContinuation?.resume(throwing: error)
      loadContinuation = nil
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    MainActor.assumeIsolated {
      loadContinuation?.resume(throwing: error)
      loadContinuation = nil
    }
  }

  private func withTimeout(seconds: UInt64, _ operation: @escaping () async throws -> Void) async throws {
    let timeoutTask = Task { @MainActor [weak self] in
      try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
      if let continuation = self?.loadContinuation {
        self?.loadContinuation = nil
        continuation.resume(throwing: InkError.rasterizationFailed("timeout"))
      }
    }
    defer { timeoutTask.cancel() }
    try await operation()
  }
}
