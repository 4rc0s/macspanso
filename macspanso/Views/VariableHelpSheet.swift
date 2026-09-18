// macspanso/Views/VariableHelpSheet.swift
import SwiftUI
import WebKit

/// Offline quick-reference sheet for variable types. Presents the bundled HTML
/// (`VariableHelpContent.html`) in a WKWebView, scrolled to the section for the
/// type whose help button was pressed; `nil` opens from the top.
/// `loadHTMLString` keeps everything self-contained — no resource to bundle,
/// no network.
struct VariableHelpSheet: View {
    let type: VarType?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Variable Reference")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            VariableHelpWebView(type: type)
        }
        .frame(width: 640, height: 560)
    }
}

/// The bare reference web view, reusable on its own: the type-picker presents it
/// in a popover, which brings its own dismissal and needs no title bar.
struct VariableHelpWebView: NSViewRepresentable {
    let type: VarType?

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // One line of JS after commit scrolls to the section — `loadHTMLString`
        // has no base URL, so a fragment in the loaded string won't do it.
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(VariableHelpContent.html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(target: anchor) }

    private var anchor: String? {
        type.flatMap { VariableHelpContent.anchor(for: $0) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let target: String?
        weak var webView: WKWebView?

        init(target: String?) { self.target = target }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let target else { return }
            webView.evaluateJavaScript("location.hash = '\(target)'")
        }
    }
}
