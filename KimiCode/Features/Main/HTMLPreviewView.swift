import SwiftUI
import WebKit

/// 工作区 HTML 的静态预览：内联样式与 data 资源可显示，脚本和外部网络资源一律禁止。
struct HTMLPreviewView: UIViewRepresentable {
    let html: String

    private let contentSecurityPolicy = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline' data:; font-src data:; media-src data:; form-action 'none'; base-uri 'none'">
        """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.allowsAirPlayForMediaPlayback = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        view.isInspectable = false
        load(view, into: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        load(view, into: context.coordinator)
    }

    private func load(_ view: WKWebView, into coordinator: Coordinator) {
        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        var secured = html
        if let head = secured.range(of: "<head", options: .caseInsensitive),
           let end = secured.range(of: ">", range: head.upperBound..<secured.endIndex) {
            secured.insert(contentsOf: contentSecurityPolicy, at: end.upperBound)
        } else {
            secured.insert(contentsOf: contentSecurityPolicy, at: secured.startIndex)
        }
        view.loadHTMLString(secured, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            decisionHandler(scheme == "http" || scheme == "https" ? .cancel : .allow)
        }
    }
}
