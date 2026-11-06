import SwiftUI
import TolkCore

struct AISettings: View {
    let app: AppState

    var body: some View {
        Form {
            AccountSection(auth: app.auth)
            ModelSections(settings: app.settings)
            UsageSection(store: app.usage, unavailableReason: app.usageError)
        }
        .formStyle(.grouped)
    }
}

private struct AccountSection: View {
    let auth: AuthController
    @State private var pasted = ""

    var body: some View {
        Section {
            switch auth.status {
            case .unknown:
                ProgressView()
            case .signedOut:
                Text("Tolk translates with your ChatGPT Plus/Pro subscription. Sign in with your browser.")
                Button("Sign in with ChatGPT…") { auth.signIn() }.buttonStyle(.borderedProminent)
            case .signingIn:
                HStack { ProgressView().controlSize(.small); Text("Waiting for the browser…") }
                Text("If the browser shows an error page after login, paste its address here:")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("http://localhost:1455/auth/callback?code=…", text: $pasted)
                    Button("Submit") { auth.submitPasted(pasted) }.disabled(pasted.isEmpty)
                }
                Button("Cancel") { auth.cancel() }
            case .signedIn(let email):
                LabeledContent("Signed in", value: email ?? "ChatGPT account")
                Button("Sign out", role: .destructive) { auth.signOut() }
                    .disabled(AppState.usesDevCredentials)
            }
            if let error = auth.error { Text(error).foregroundStyle(.red).font(.caption) }
        } header: {
            Text("ChatGPT account")
        } footer: {
            Text("Requests count toward your ChatGPT subscription limits. Credentials are stored in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ModelSections: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("Live translation") { ModelPicker(choice: $settings.liveModel) }
        Section("Phrase suggestions") { ModelPicker(choice: $settings.suggestionsModel) }
        Button("Reset models to defaults") {
            settings.liveModel = .liveDefault
            settings.suggestionsModel = .suggestionsDefault
        }
    }
}

private struct ModelPicker: View {
    @Binding var choice: ModelChoice

    var body: some View {
        Picker("Model", selection: $choice.model) {
            ForEach(ModelChoice.knownModels, id: \.self) { Text($0).tag($0) }
            if !ModelChoice.knownModels.contains(choice.model) { Text(choice.model).tag(choice.model) }
        }
        Picker("Reasoning effort", selection: Binding(get: { choice.effort ?? "none" }, set: { choice.effort = $0 })) {
            ForEach(ModelChoice.efforts, id: \.self) { Text($0).tag($0) }
        }
    }
}

private struct UsageSection: View {
    let store: UsageStore?
    let unavailableReason: String?
    @State private var period: UsagePeriod = .today

    var body: some View {
        Section {
            if let store {
                Picker("Period", selection: $period) {
                    ForEach(UsagePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                // Refresh Today at midnight even if Settings stays open without new requests.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    switch Result(catching: { try store.summary(period: period, now: context.date) }) {
                    case .success(let summary): UsageContent(summary: summary)
                    case .failure:
                        Text("Could not read usage. Restart Tolk to try again.").foregroundStyle(.red)
                    }
                }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            } else {
                Text(unavailableReason ?? "Usage tracking is unavailable.").foregroundStyle(.red)
                Text("Restart Tolk to try again.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Recorded locally by Tolk on this Mac, across signed-in accounts. Not account-wide usage or billing; no dollar costs are estimated. Stopped requests may leave gaps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct UsageContent: View {
    let summary: UsageSummary
    private var totals: UsageTotals { summary.totals }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if totals.reportedRequests == 0 {
                Text("No token data yet").font(.headline).accessibilityIdentifier("usage-empty")
                Text("Make a translation or find a phrase. Counts appear when ChatGPT reports token usage.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                tokenRow("Total tokens", value: totals.totalTokens.formatted(), identifier: "usage-total")
                    .font(.headline)
                tokenRow("Input", value: totals.inputTokens.formatted(), identifier: "usage-input")
                tokenRow("Output", value: totals.outputTokens.formatted(), identifier: "usage-output")
                tokenRow("Cached input", value: breakdown(totals.cachedInputTokens, reports: totals.cachedReports, of: totals.reportedRequests), identifier: "usage-cached")
                tokenRow("Reasoning output", value: breakdown(totals.reasoningOutputTokens, reports: totals.reasoningReports, of: totals.reportedRequests), identifier: "usage-reasoning")
                Text("Cached input and reasoning are included in input and output. Partial breakdowns cover only requests that reported them.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("By requested model").font(.subheadline).fontWeight(.semibold)
                ForEach(summary.models) { model in
                    VStack(alignment: .leading, spacing: 3) {
                        LabeledContent(model.model) {
                            Text(model.totals.reportedRequests > 0 ? "\(model.totals.totalTokens.formatted()) tokens" : "Not reported")
                                .monospacedDigit()
                        }
                        if model.totals.reportedRequests > 0 {
                            Text("\(model.totals.inputTokens.formatted()) input · \(model.totals.outputTokens.formatted()) output")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.totals.cachedReports > 0 || model.totals.reasoningReports > 0 {
                            HStack(spacing: 12) {
                                if model.totals.cachedReports > 0 {
                                    Text("Cached input: \(breakdown(model.totals.cachedInputTokens, reports: model.totals.cachedReports, of: model.totals.reportedRequests))")
                                        .accessibilityIdentifier("usage-model-\(model.model)-cached")
                                }
                                if model.totals.reasoningReports > 0 {
                                    Text("Reasoning: \(breakdown(model.totals.reasoningOutputTokens, reports: model.totals.reasoningReports, of: model.totals.reportedRequests))")
                                        .accessibilityIdentifier("usage-model-\(model.model)-reasoning")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if totals.unreportedRequests > 0 {
                Text("No token counts for \(requests(totals.unreportedRequests)). Totals may be incomplete.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("usage-unreported")
            }
            if totals.invalidUsageRequests > 0 {
                Text("Invalid usage data for \(requests(totals.invalidUsageRequests)); excluded from totals.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private func tokenRow(_ label: String, value: String, identifier: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit().accessibilityIdentifier(identifier) }
    }

    private func breakdown(_ tokens: Int64, reports: Int64, of totalReports: Int64) -> String {
        guard reports > 0 else { return "Not reported" }
        return reports == totalReports ? tokens.formatted() : "\(tokens.formatted()) (partial)"
    }

    private func requests(_ count: Int64) -> String { "\(count.formatted()) \(count == 1 ? "request" : "requests")" }
}
