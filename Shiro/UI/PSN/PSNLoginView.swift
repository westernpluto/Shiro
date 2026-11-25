import SwiftUI
import WebKit

/// Sony's PlayStation sign-in page in an in-app browser. When Sony redirects
/// to the Remote Play redirect URL we capture the authorization code.
struct PSNLoginView: View {
    @EnvironmentObject private var psn: PSNAuth
    @EnvironmentObject private var store: ConsoleStore
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var showPaste = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PSNWebView { code in
                    Task { await finish(code: code) }
                }
                if working {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    ProgressView("Signing in…").tint(.white).foregroundStyle(.white)
                }
            }
            .navigationTitle("PlayStation Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showPaste = true } label: { Label("Paste redirect URL", systemImage: "doc.on.clipboard") }
                }
            }
            .alert("Paste redirect URL", isPresented: $showPaste) {
                TextField("https://remoteplay.dl.playstation.net/…?code=…", text: $pasted)
                    .textInputAutocapitalization(.never)
                Button("Sign in") {
                    if let code = PSNAuth.code(from: pasted) { Task { await finish(code: code) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If the page doesn't close by itself after signing in, copy the address of the final page and paste it here.")
            }
            .alert("Sign-in failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func finish(code: String) async {
        guard !working else { return }
        working = true
        do {
            try await psn.signIn(code: code)
            await store.refreshPSNDevices()
            working = false
            dismiss()
        } catch {
            working = false
            self.error = error.localizedDescription
        }
    }
}

struct PSNWebView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        // The OAuth client is Sony's Windows Remote Play app, and Sony's push
        // service appears to treat tokens by the login environment, so sign in
        // with a desktop browser identity like chiaki-ng's login does.
        web.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
        web.load(URLRequest(url: PSNAuth.loginURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               url.absoluteString.hasPrefix(PSNAuth.redirectURL),
               let code = PSNAuth.code(from: url.absoluteString) {
                decisionHandler(.cancel)
                if !delivered {
                    delivered = true
                    onCode(code)
                }
                return
            }
            decisionHandler(.allow)
        }
    }
}
