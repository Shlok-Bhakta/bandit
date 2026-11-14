import BandCredentials
import BandKit
import BandLogging
import SwiftUI
import WebKit

/// Meta's own sign-in page in a non-persistent web view. The app never sees the password: it
/// intercepts only the `fb-viewapp://frl_login` callback (token + encrypted blob) and exchanges it.
struct MetaLoginView: View {
    var onSession: (MetaSession) -> Void
    @Environment(\.dismiss) private var dismiss
    enum Phase { case intro, querying, signingIn, exchanging }
    @State private var phase: Phase = .intro
    @State private var error: String?
    @State private var tokens: MetaAuth.SSOTokens?
    @State private var host = "auth.meta.com"

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .intro: intro
                case .querying: waiting("Opening Meta's sign-in…")
                case .signingIn:
                    if let url = tokens?.authEntryURL {
                        AuthWebView(url: url, onHost: { host = $0 }, onCallback: handleCallback)
                            .ignoresSafeArea(edges: .bottom)
                    }
                case .exchanging: waiting("Finishing the sign-in…")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error {
                    VStack(spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).font(.callout)
                        Button("Try again") { begin() }.buttonStyle(.borderedProminent)
                    }
                    .padding().frame(maxWidth: .infinity).background(.ultraThinMaterial)
                }
            }
            .navigationTitle(phase == .intro ? "Sign in with Meta" : host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { logInfo(.meta, "Sign-in cancelled"); dismiss() } }
                if phase != .intro {
                    ToolbarItem(placement: .principal) {
                        Label(host, systemImage: "lock.fill").font(.footnote.weight(.semibold)).labelStyle(.titleAndIcon)
                    }
                }
            }
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Claiming a band needs one Meta sign-in. After that, connecting uses only the owner key saved on this iPhone.")
                    .font(.title3)
                promise("lock.shield", "You sign in on Meta's page", "The page is auth.meta.com, and its host is shown at the top. Your password goes only to Meta. The app gets a session token back.")
                promise("key", "Token kept separate from your band key", "The Meta session goes in its own Keychain item. You can forget it at any time without affecting the band.")
                promise("exclamationmark.arrow.triangle.2.circlepath", "One owner at a time", "Claiming unlinks the band from the Meta AI app and any glasses until you factory reset it (hold its button ~16 s).")
                Button { begin() } label: {
                    Label("Continue to Meta", systemImage: "arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(24)
        }
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 30).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 14) {
            if error == nil { ProgressView() }
            Text(text).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func begin() {
        error = nil
        phase = .querying
        logNotice(.meta, "Starting Meta sign-in")
        Task {
            do {
                tokens = try await MetaAuth.tokensQuery()
                phase = .signingIn
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func handleCallback(_ url: URL) {
        guard phase == .signingIn, let tokens else { return }
        guard let blob = MetaAuth.blob(fromCallback: url, tokens: tokens) else {
            logWarning(.meta, "Ignored a sign-in callback whose token didn't match this sign-in")
            error = "Meta didn't confirm this sign-in. Try again."
            return
        }
        logInfo(.meta, "Sign-in callback received; exchanging for an account session")
        phase = .exchanging
        Task {
            do {
                let frl = try await MetaAuth.decryptBlob(blob, tokens: tokens)
                let session = try await MetaAuth.login(frlAccessToken: frl)
                onSession(session)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                phase = .signingIn
            }
        }
    }
}

private struct AuthWebView: UIViewRepresentable {
    let url: URL
    var onHost: (String) -> Void
    let onCallback: (URL) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Fallback: catch the custom-scheme callback even if it isn't seen as a navigation.
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "fb-viewapp")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onHost: onHost, onCallback: onCallback) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {
        let onHost: (String) -> Void
        let onCallback: (URL) -> Void
        private var delivered = false

        init(onHost: @escaping (String) -> Void, onCallback: @escaping (URL) -> Void) {
            self.onHost = onHost
            self.onCallback = onCallback
        }

        private func deliver(_ url: URL) {
            guard !delivered else { return }
            delivered = true
            onCallback(url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let host = webView.url?.host {
                onHost(host)
                logInfo(.meta, "Sign-in page at \(host)")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if MetaAuth.isCallback(url) {
                decisionHandler(.cancel)
                deliver(url)
                return
            }
            let scheme = url.scheme?.lowercased()
            decisionHandler(scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logWarning(.meta, "Sign-in page navigation failed: \(BandLog.describe(error))")
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            if let url = urlSchemeTask.request.url { deliver(url) }
            urlSchemeTask.didFailWithError(URLError(.cancelled))
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }
}
