import AppKit
import Observation
import TolkCore

/// App-wide wiring: settings, auth, translator model, history, and local usage.
@MainActor
@Observable
final class AppState {
    let settings: AppSettings
    let auth: AuthController
    enum Screen: String, CaseIterable {
        case translation = "Translate"
        case phraseFinder = "Find a phrase"
    }

    let translator: TranslatorModel
    let finder: PhraseFinderModel
    let history: HistoryStore?
    let usage: UsageStore?
    var usageError: String?
    private let pasteboard: NSPasteboard
    var screen: Screen = .translation {
        didSet { if screen == .phraseFinder { showHistory = false } }
    }
    /// Bumped after history writes so list views refresh.
    private(set) var historyRevision = 0
    var showHistory = false {
        didSet { if showHistory { screen = .translation } }
    }
    var historyError: String?

    /// Dev only: `TOLK_DEV_PI_TOKEN=1` uses Pi's ChatGPT token (read-only) instead of the Keychain login.
    static let usesDevCredentials = ProcessInfo.processInfo.environment["TOLK_DEV_PI_TOKEN"] == "1"

    convenience init() {
        // Dev runs keep their settings and history apart from the user's.
        let settings = Self.usesDevCredentials
            ? AppSettings(defaults: UserDefaults(suiteName: "dev.stas.tolk.devrun")!) : AppSettings()
        let auth = AuthController(manager: AuthManager(store: KeychainCredentialStore()))
        let credentials: CodexCredentialSource = Self.usesDevCredentials ? PiDevCredentialSource() : auth.manager
        let history: HistoryStore?
        let historyError: String?
        do {
            history = try HistoryStore(fileName: Self.usesDevCredentials ? "History-dev.store" : "History.store")
            historyError = nil
        } catch {
            history = nil
            historyError = "History unavailable: \(error.localizedDescription)"
        }
        let usage: UsageStore?
        let usageError: String?
        do {
            usage = try UsageStore(fileName: Self.usesDevCredentials ? "Usage-dev.store" : "Usage.store")
            usageError = nil
        } catch {
            usage = nil
            usageError = "Usage tracking unavailable: \(error.localizedDescription)"
        }
        let provider = CodexClient(credentials: credentials, onUsage: { observation in await usage?.record(observation) })
        self.init(settings: settings, auth: auth, provider: provider, history: history, usage: usage)
        self.historyError = historyError
        self.usageError = usageError
    }

    init(settings: AppSettings, auth: AuthController, provider: any LLMProvider, history: HistoryStore?,
         usage: UsageStore? = nil, pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.auth = auth
        self.history = history
        self.usage = usage
        self.pasteboard = pasteboard
        translator = TranslatorModel(settings: settings, provider: provider)
        finder = PhraseFinderModel(settings: settings, provider: provider)
        translator.recordHistory = { [weak self] candidate in self?.record(candidate) }
        auth.onSignedIn = { [weak self] in
            self?.translator.clearSignInFailure()
            self?.finder.clearSignInFailure()
        }
    }

    private func record(_ candidate: HistoryCandidate) {
        guard let history else { return }
        do {
            if try history.record(candidate) != .skip { historyRevision += 1 }
        } catch {
            historyError = "Could not save history: \(error.localizedDescription)"
        }
    }

    func historyChanged() { historyRevision += 1 }

    func restore(_ entry: HistoryEntry) {
        loadTranslation(text: entry.sourceText, source: entry.sourceLanguage.isEmpty ? .detect : .language(entry.sourceLanguage),
                        target: entry.targetLanguage, translation: entry.translation, tone: entry.tone)
        showHistory = false
    }

    /// Every external translation entry point must reveal the translation, not a hidden draft.
    func loadTranslation(text: String, source: TranslatorModel.SourceChoice = .detect, target: String? = nil,
                         translation: String? = nil, tone: Tone? = nil) {
        screen = .translation
        translator.load(text: text, source: source, target: target, translation: translation, tone: tone)
    }

    var primaryActionRequiresSignIn: Bool {
        screen == .translation ? translator.failure?.requiresSignIn == true : finder.failure?.requiresSignIn == true
    }

    var primaryActionTitle: String {
        if primaryActionRequiresSignIn { return "Sign in…" }
        if screen == .translation { return "Translate now" }
        if finder.isSearching { return "Stop search" }
        return finder.failure == nil ? "Find phrases" : "Retry search"
    }

    func canPerform(_ action: InAppAction) -> Bool {
        switch action {
        case .translate:
            return screen == .translation ? !translator.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : finder.canSearch || finder.isSearching
        case .history: return true
        case .copyTranslation: return screen == .translation && translator.canCopyTranslation
        default: return screen == .translation
        }
    }

    func performPrimaryAction() {
        guard canPerform(.translate), !primaryActionRequiresSignIn else { return }
        if screen == .translation { translator.translateNow() }
        else if finder.isSearching { finder.stop() }
        else { finder.find() }
    }

    @discardableResult
    func copyPhrase(_ phrase: PhraseSuggestion) -> Bool {
        guard screen == .phraseFinder, finder.result?.items.contains(phrase) == true else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(phrase.text, forType: .string)
    }

    func copyTranslation() {
        guard canPerform(.copyTranslation) else { return }
        pasteboard.clearContents()
        pasteboard.setString(translator.translation, forType: .string)
        translator.commitHistory()
    }
}

/// Drives the browser-based ChatGPT sign-in.
@MainActor
@Observable
final class AuthController {
    enum Status: Equatable {
        case unknown, signedOut, signingIn, signedIn(email: String?)
    }

    let manager: AuthManager
    private(set) var status: Status = .unknown
    private(set) var error: String?
    /// Explicit successful login, not a status refresh of an existing (possibly expired) session.
    var onSignedIn: () -> Void = {}
    private var flow: (pkce: PKCE, state: String)?
    private var server: OAuthCallbackServer?
    private var loginTask: Task<Void, Never>?
    private var pasteTask: Task<Void, Never>?
    /// Credential writes run one at a time in call order, so a sign-out requested while a sign-in
    /// is being saved always lands last.
    private let credentialWrites = SerialQueue()

    init(manager: AuthManager) {
        self.manager = manager
        Task { await refreshStatus() }
    }

    /// Shows the stored session, unless a sign-in attempt is in progress (it owns the status then).
    func refreshStatus() async {
        if AppState.usesDevCredentials { status = .signedIn(email: "Pi dev token"); return }
        do {
            let creds = try await manager.credentials()
            guard flow == nil else { return }
            status = creds.map { .signedIn(email: $0.email) } ?? .signedOut
        } catch {
            self.error = error.localizedDescription
            guard flow == nil else { return }
            status = .signedOut
        }
    }

    func signIn() {
        cancel()
        error = nil
        status = .signingIn
        let pkce = PKCE.generate(), state = CodexOAuth.newState()
        flow = (pkce, state)
        let url = CodexOAuth.authorizationURL(pkce: pkce, state: state)
        loginTask = Task {
            do {
                let server = try OAuthCallbackServer(state: state)
                self.server = server
                try await server.start()
                NSWorkspace.shared.open(url)
                let code = try await server.waitForCode()
                try await finish(code: code, state: state, verifier: pkce.verifier)
            } catch OAuthCallbackServer.CallbackError.cancelled {
                // User cancelled or pasted a URL instead.
            } catch is CancellationError {
            } catch {
                // Port busy etc.: still open the browser so the user can paste the redirect URL.
                if case OAuthCallbackServer.CallbackError.portUnavailable = error { NSWorkspace.shared.open(url) }
                self.error = error.localizedDescription
            }
        }
    }

    /// Fallback when the localhost callback cannot be received: paste the redirect URL from the browser.
    func submitPasted(_ input: String) {
        guard let flow else { return }
        let parsed = CodexOAuth.parseAuthorizationInput(input)
        if let state = parsed.state, state != flow.state { error = "That link belongs to a different sign-in attempt."; return }
        guard let code = parsed.code else { error = "No authorization code found."; return }
        server?.stop()
        pasteTask?.cancel()
        pasteTask = Task {
            do { try await finish(code: code, state: flow.state, verifier: flow.pkce.verifier) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }

    /// Exchanges the code and saves credentials, unless the attempt was cancelled or superseded meanwhile.
    private func finish(code: String, state: String, verifier: String) async throws {
        let creds = try await CodexOAuth.exchangeCode(code, verifier: verifier)
        guard !Task.isCancelled, flow?.state == state else { throw CancellationError() }
        // Credential writes are linearized: an attempt cancelled before its save starts is dropped; one
        // whose save already started has completed, and a later Cancel/Sign out is ordered after it.
        let saved = try await credentialWrites.run { () -> Bool in
            guard self.flow?.state == state else { return false }
            try await self.manager.signIn(creds)
            return true
        }
        guard saved else { throw CancellationError() }
        guard flow?.state == state else {
            // Cancel arrived during the save; sign-in still completed. A newer attempt keeps its own status.
            await refreshStatus()
            return
        }
        server?.stop()
        server = nil
        flow = nil
        status = .signedIn(email: creds.email)
        onSignedIn()
        NSApp.activate()
    }

    func cancel() {
        loginTask?.cancel()
        loginTask = nil
        pasteTask?.cancel()
        pasteTask = nil
        flow = nil
        server?.stop()
        server = nil
        // A cancelled re-login keeps the existing session; reflect what is stored.
        if status == .signingIn {
            Task {
                await credentialWrites.drain()
                await refreshStatus()
            }
        }
    }

    func signOut() {
        cancel()
        Task {
            do { try await credentialWrites.run { try await self.manager.signOut() } }
            catch { self.error = error.localizedDescription }
            await refreshStatus()
        }
    }
}
