//
//  GithubprsDroplet.swift
//  Githubprs
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(GithubprsPrincipal)
public final class GithubprsPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { GithubprsDroplet() }
}

/// GitHub pull requests that are waiting on you: reviews requested from you,
/// and your own PRs with changes requested, failing checks, conflicts, or an
/// approval waiting for a merge.
@MainActor
public final class GithubprsDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "githubprs"

    public enum Status: Equatable {
        case needsToken
        case loading
        case loaded
        case failed(String)
    }

    @Published public private(set) var items: [AttentionPR] = []
    @Published public private(set) var status: Status = .needsToken
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var hasToken = false

    /// What a harness hands the droplet in place of a Keychain token. Droppy
    /// always creates the droplet with `.none`, through the principal class.
    public enum Seed: Sendable {
        case none
        /// Fixed rows instead of a fetch, and one alert on activation: the
        /// Store screenshots.
        case items([AttentionPR])
        /// A token to fetch with when the Keychain has none.
        case token(String)
    }

    private let seed: Seed
    private var host: DropletHost?
    private var ticker: AnyCancellable?
    private var preferenceChanges: AnyCancellable?
    private var fetchTask: Task<Void, Never>?

    public override convenience init() {
        self.init(seed: .none)
    }

    public init(seed: Seed) {
        self.seed = seed
        super.init()
    }

    private var seededItems: [AttentionPR]? {
        if case .items(let items) = seed { return items }
        return nil
    }

    public func activate(host: DropletHost) throws {
        self.host = host
        hasToken = token != nil || seededItems != nil
        status = hasToken ? .loading : .needsToken
        preferenceChanges = host.preferences.didChange
            .receive(on: RunLoop.main)
            .sink { [weak self] key in
                guard let self else { return }
                if key == Keys.interval { self.scheduleTicker() }
                if Keys.refetching.contains(key) { self.refresh() }
            }
        scheduleTicker()
        registerShortcut(on: host)
        refresh()
        if let first = seededItems?.first { presentAlert(for: [first]) }
    }

    // MARK: - Shortcut

    static let widgetID: ShelfWidgetID = "githubprs"

    /// One global shortcut, rebindable on Droppy's Shortcuts page: it opens
    /// the shelf on this widget, and closes it again when it is already
    /// showing. ⌃⌥⌘G is only a suggestion; the host drops it if it collides.
    private func registerShortcut(on host: DropletHost) {
        guard host.isGranted(.globalShortcuts) else { return }
        host.shortcuts.register(
            id: "show-widget",
            title: "Show GitHub PRs",
            defaultShortcut: DropletKeyboardShortcut(
                keyCode: 5, // G
                modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
            )
        ) { [weak self] in
            self?.toggleShelf()
        }
    }

    public func toggleShelf() {
        guard let shelf = host?.shelf else { return }
        if shelf.isExpanded, shelf.soloWidgetID == Self.widgetID {
            shelf.close()
        } else {
            shelf.open(revealing: Self.widgetID)
            refresh()
        }
    }

    public func openShortcuts() {
        host?.workspace.openShortcuts()
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        ticker = nil
        preferenceChanges = nil
        fetchTask?.cancel()
        fetchTask = nil
        host = nil
    }

    // MARK: - Token

    /// The Keychain token, or the one a harness seeded.
    private var token: String? {
        if let stored = TokenStore.read() { return stored }
        if case .token(let seeded) = seed, !seeded.isEmpty { return seeded }
        return nil
    }

    public func saveToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard TokenStore.save(trimmed) else {
            host?.log.error("Could not save the token to the Keychain")
            hasToken = token != nil
            status = .failed("The token could not be saved to your Keychain")
            return
        }
        hasToken = true
        refresh()
    }

    public func removeToken() {
        TokenStore.delete()
        hasToken = token != nil
        if !hasToken {
            fetchTask?.cancel()
            items = []
            status = .needsToken
        }
    }

    // MARK: - Fetching

    public func refresh() {
        guard let host else { return }
        if let seededItems {
            items = seededItems
            lastUpdated = Date()
            status = .loaded
            return
        }
        guard let token else {
            status = .needsToken
            items = []
            return
        }
        guard host.isGranted(.networkClient) else {
            status = .failed("Network access is switched off")
            return
        }
        if items.isEmpty { status = .loading }
        fetchTask?.cancel()
        let options = fetchOptions
        fetchTask = Task { [weak self] in
            do {
                let result = try await GitHubClient(token: token).fetchAttention(options: options)
                guard !Task.isCancelled, let self else { return }
                self.announceNewArrivals(in: result, options: options)
                self.items = result
                self.lastUpdated = Date()
                self.status = .loaded
            } catch {
                guard !Task.isCancelled, let self else { return }
                if (error as? URLError)?.code == .cancelled { return }
                self.host?.log.error("GitHub fetch failed: \(error.localizedDescription)")
                // A rejected token makes the old list a lie; anything else
                // (offline, rate limited) keeps it, flagged in the header.
                if case GitHubClientError.unauthorized = error { self.items = [] }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func scheduleTicker() {
        ticker = Timer.publish(every: TimeInterval(refreshMinutes * 60), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Opens only https links on github.com: the URL comes off the network,
    /// and the host would otherwise hand any scheme to the system.
    public func open(_ pr: AttentionPR) {
        guard pr.url.scheme == "https", pr.url.host == "github.com" else {
            host?.log.error("Refused to open a pull request link outside github.com")
            return
        }
        host?.workspace.open(pr.url)
    }

    public func openSettings() {
        host?.workspace.openSettings()
    }

    /// The whole list on github.com, for when the widget runs out of rows.
    public func openAllOnGitHub() {
        host?.workspace.open(fetchOptions.webSearchURL)
    }

    var fetchOptions: GitHubClient.Options {
        GitHubClient.Options(
            includeDrafts: includeDrafts, includeAssigned: includeAssigned,
            scopes: scopes, includeOthers: includeOthers
        )
    }

    // MARK: - New pull request alerts

    /// Reasons that mean someone else opened a PR that now involves you or a
    /// repository you watch. Your own PRs changing state are not "new".
    private static let arrivalReasons: Set<AttentionReason> = [.reviewRequested, .assigned, .open]

    /// Compares a fetch with the PRs already seen and puts the new ones on
    /// the notch. The first fetch, and the first after the filters change,
    /// only records a baseline: adding a busy organisation should not fire
    /// one alert per open pull request.
    private func announceNewArrivals(in result: [AttentionPR], options: GitHubClient.Options) {
        guard let preferences = host?.preferences else { return }
        let signature = options.baselineSignature
        let seen = Set(preferences.value(forKey: Keys.seenIDs, default: [String]()))
        let hasBaseline = preferences.value(forKey: Keys.seenSignature, as: String.self) == signature

        // Keyed on the reason too, so a PR first seen as merely open still
        // alerts when a review is requested from you on it.
        preferences.setValue(result.map(\.seenKey), forKey: Keys.seenIDs)
        preferences.setValue(signature, forKey: Keys.seenSignature)

        guard hasBaseline, alertsEnabled else { return }
        let arrivals = result.filter { Self.arrivalReasons.contains($0.reason) && !seen.contains($0.seenKey) }
        guard !arrivals.isEmpty else { return }
        host?.log.info("\(arrivals.count) new pull request(s)")
        presentAlert(for: arrivals)
    }

    func presentAlert(for arrivals: [AttentionPR]) {
        guard let host, let first = arrivals.first else { return }
        let count = arrivals.count
        let heading = count == 1 ? first.reason.arrivalHeading : "\(count) new pull requests"
        let request = DropletHUDRequest(
            id: "githubprs.new",
            duration: 6,
            priority: .normal,
            accessibilityLabel: "\(heading): \(first.title)",
            isExpanded: true,
            expandedContentHeight: 54
        ) {
            // A strip keeps to the two outer edges; the middle is the camera.
            HStack(spacing: 0) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                Spacer(minLength: 0)
                Text(verbatim: count == 1 ? "New PR" : "\(count) new")
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        } expanded: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DroppySpacing.xsm) {
                    Image(systemName: first.reason.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(first.reason.tint)
                    Text(verbatim: heading)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
                Text(verbatim: first.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(verbatim: count == 1
                    ? "\(first.shortReference) by \(first.author)"
                    : "\(first.shortReference) and \(count - 1) more")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A refusal is normal: Droppy's own HUDs or an open shelf may own the
        // notch. The PR is still in the widget, so nothing retries.
        _ = host.hud.present(request)
    }

    // MARK: - Preferences

    enum Keys {
        static let interval = "refreshMinutes"
        static let includeDrafts = "includeDrafts"
        static let includeAssigned = "includeAssigned"
        static let scopes = "scopes"
        static let includeOthers = "includeOthers"
        static let alertsEnabled = "alertsEnabled"
        static let seenIDs = "seenIDs"
        static let seenSignature = "seenSignature"

        static let refetching: Set<String> = [includeDrafts, includeAssigned, scopes, includeOthers]
    }

    public var refreshMinutes: Int {
        max(1, host?.preferences.value(forKey: Keys.interval, default: 5) ?? 5)
    }

    public var includeDrafts: Bool {
        host?.preferences.value(forKey: Keys.includeDrafts, default: false) ?? false
    }

    public var includeAssigned: Bool {
        host?.preferences.value(forKey: Keys.includeAssigned, default: true) ?? true
    }

    public var scopes: [String] {
        host?.preferences.value(forKey: Keys.scopes, default: [String]()) ?? []
    }

    public var includeOthers: Bool {
        host?.preferences.value(forKey: Keys.includeOthers, default: false) ?? false
    }

    public var alertsEnabled: Bool {
        host?.preferences.value(forKey: Keys.alertsEnabled, default: true) ?? true
    }

    /// Adds `owner` or `owner/repo`. Returns `false` when it is not either.
    @discardableResult
    public func addScope(_ raw: String) -> Bool {
        guard let scope = GitHubClient.Options.normalizedScope(raw) else { return false }
        var current = scopes
        guard !current.contains(where: { $0.caseInsensitiveCompare(scope) == .orderedSame }) else { return true }
        current.append(scope)
        objectWillChange.send()
        host?.preferences.setValue(current, forKey: Keys.scopes)
        return true
    }

    public func removeScope(_ scope: String) {
        objectWillChange.send()
        host?.preferences.setValue(scopes.filter { $0 != scope }, forKey: Keys.scopes)
    }

    func binding<Value: Codable & Sendable>(_ key: String, _ current: @escaping @MainActor @Sendable () -> Value) -> Binding<Value> {
        Binding(
            get: { MainActor.assumeIsolated { current() } },
            set: { [weak self] in
                self?.objectWillChange.send()
                self?.host?.preferences.setValue($0, forKey: key)
            }
        )
    }

    // MARK: - Widget-facing

    /// Stand-in rows for the shelf's widget gallery preview, and what the
    /// harness seeds for the Store screenshots.
    public static let sampleItems: [AttentionPR] = [
        .init(id: "1", number: 482, title: "Add retry budget to the sync worker", url: URL(string: "https://github.com")!,
              repository: "acme/api", author: "mara", updatedAt: Date().addingTimeInterval(-1_800), reason: .reviewRequested),
        .init(id: "2", number: 77, title: "Migrate settings to the new store", url: URL(string: "https://github.com")!,
              repository: "acme/web", author: "you", updatedAt: Date().addingTimeInterval(-7_200), reason: .changesRequested),
        .init(id: "3", number: 391, title: "Stream build logs over websockets", url: URL(string: "https://github.com")!,
              repository: "acme/ci", author: "you", updatedAt: Date().addingTimeInterval(-10_800), reason: .checksFailing),
        .init(id: "4", number: 58, title: "Rename billing tables", url: URL(string: "https://github.com")!,
              repository: "acme/db", author: "you", updatedAt: Date().addingTimeInterval(-28_800), reason: .conflicts),
        .init(id: "5", number: 1203, title: "Bump Swift to 6.2", url: URL(string: "https://github.com")!,
              repository: "acme/ios", author: "you", updatedAt: Date().addingTimeInterval(-86_400), reason: .readyToMerge),
        .init(id: "6", number: 940, title: "Fix flaky checkout test", url: URL(string: "https://github.com")!,
              repository: "acme/web", author: "jun", updatedAt: Date().addingTimeInterval(-172_800), reason: .assigned),
    ]
}

// MARK: - Shelf widget

extension GithubprsDroplet: ShelfWidgetCompositionProviding {
    /// Rows that fit without scrolling; past this the list scrolls and ends
    /// with a link to the same search on GitHub.
    static let soloRows = 5

    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "GitHub PRs",
                systemImage: "arrow.triangle.pull",
                layoutTraits: ShelfWidgetLayoutTraits(
                    // Header 34 + 10, then five 22pt rows 4 apart: 170.
                    single: ShelfWidgetModeSize(width: 420, contentHeight: 170),
                    // Header 28 + 8, three 20pt reason rows 4 apart, then
                    // the latest title on up to two lines: 150.
                    split: ShelfWidgetModeSize(width: 210, contentHeight: 150),
                    // ShelfWidgetScaffold draws ShelfWidgetHeader at the top.
                    header: .standard
                )
            )
        ]
    }

    public func makeWidgetContent(_ id: ShelfWidgetID, layout: ShelfWidgetLayout) -> AnyView {
        AnyView(GithubprsWidget(droplet: self, layout: layout))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension AttentionPR {
    /// What the new-PR alert remembers: the PR and why it is on the list.
    var seenKey: String { "\(id):\(reason.rawValue)" }
}

extension AttentionReason {
    var arrivalHeading: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .assigned: "Assigned to you"
        default: "New pull request"
        }
    }

    var tint: Color {
        switch self {
        case .reviewRequested: .blue
        case .changesRequested: .orange
        case .checksFailing, .conflicts: .red
        case .readyToMerge: .green
        case .assigned: AdaptiveColors.notchSurfaceSecondaryText
        case .open: AdaptiveColors.notchSurfaceTertiaryText
        }
    }
}

private struct GithubprsWidget: View {
    @ObservedObject var droplet: GithubprsDroplet
    let layout: ShelfWidgetLayout

    private var showsSamples: Bool { layout.isPreview && droplet.items.isEmpty }

    private var items: [AttentionPR] {
        showsSamples ? GithubprsDroplet.sampleItems : droplet.items
    }

    /// Which filter is on, so a scoped list never reads as all of GitHub.
    private var scopeSummary: String? {
        let scopes = droplet.scopes
        guard let first = scopes.first else { return nil }
        return scopes.count == 1 ? first : "\(first) +\(scopes.count - 1)"
    }

    /// The header counts what asks something of you, not every open PR.
    private var needsYouCount: Int { items.filter(\.reason.needsYou).count }

    /// The header's title is the widget's state, never its name: how many
    /// pull requests wait on you, and alone on an unwrapped shelf the filter
    /// they come from. Beside the camera it stays short enough for the band.
    private var headerTitle: String {
        let state: String
        switch (showsSamples ? .loaded : droplet.status) {
        case .needsToken:
            state = "No token"
        case .loading where items.isEmpty:
            state = "Loading"
        case .failed where items.isEmpty:
            state = "Refresh failed"
        default:
            state = needsYouCount == 0 ? "All clear" : "\(needsYouCount) waiting"
        }
        guard layout.isSingle, layout.notchWrap == nil, let scope = scopeSummary else { return state }
        return "\(state) · \(scope)"
    }

    var body: some View {
        DropletWidgetComposition {
            scaffold { soloList }
        } split: {
            scaffold { pairedSummary }
        }
    }

    private func scaffold<List: View>(@ViewBuilder list: () -> List) -> some View {
        let list = list()
        return ShelfWidgetScaffold(headerTitle, systemImage: "arrow.triangle.pull") {
            headerControls
        } content: {
            content(list)
        }
    }

    @ViewBuilder
    private var headerControls: some View {
        // The list is still shown after a failed refresh; this says it is stale.
        if case .failed(let error) = droplet.status, !items.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .help(error)
                .accessibilityLabel("Refresh failed: \(error)")
                .transition(DroppyTransition.element)
        }
        if droplet.hasToken {
            Button {
                droplet.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(DroppyWashCircleButtonStyle(
                diameter: layout.metrics.headerControlSize,
                usesAdaptiveForegrounds: layout.usesAdaptiveForegrounds
            ))
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
    }

    private func pill(_ tone: DroppyWashTone = .neutral, height: CGFloat? = nil) -> DroppyWashPillButtonStyle {
        DroppyWashPillButtonStyle(
            height: height ?? layout.metrics.controlSize,
            tone: tone,
            usesAdaptiveForegrounds: layout.usesAdaptiveForegrounds
        )
    }

    @ViewBuilder
    private func content<List: View>(_ list: List) -> some View {
        if showsSamples {
            list
        } else {
            switch droplet.status {
            case .needsToken:
                message("Add a GitHub token to see the pull requests waiting on you.") {
                    Button("Open settings") { droplet.openSettings() }
                        .buttonStyle(pill(.accent(.accentColor)))
                }
            case .loading where items.isEmpty:
                message("Loading pull requests…")
            case .failed(let error) where items.isEmpty:
                message(error) {
                    Button("Try again") { droplet.refresh() }
                        .buttonStyle(pill())
                }
            default:
                if items.isEmpty {
                    message("Nothing is waiting on you.")
                } else {
                    list
                }
            }
        }
    }

    /// Solo: every PR, most recently updated first, scrolling past five rows.
    private var soloList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: DroppySpacing.xs) {
                ForEach(items) { pr in
                    PRRow(pr: pr) { droplet.open(pr) }
                }
                if items.count > GithubprsDroplet.soloRows {
                    Button("Open the list on GitHub") { droplet.openAllOnGitHub() }
                        .buttonStyle(pill(height: layout.metrics.listRowControlSize))
                        .padding(.top, DroppySpacing.xs)
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Paired: the count by reason, and the most recent PR to click.
    private var pairedSummary: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            ForEach(reasonCountsForView.prefix(3), id: \.0) { reason, count in
                HStack(spacing: DroppySpacing.xsm) {
                    Image(systemName: reason.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(reason.tint)
                        .frame(width: 14)
                    Text(reason.shortLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                }
                .frame(height: 20)
            }
            if let first = items.first {
                Button { droplet.open(first) } label: {
                    Text(first.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, DroppySpacing.xs)
                .help(first.shortReference)
            }
        }
    }

    private var reasonCountsForView: [(AttentionReason, Int)] {
        AttentionReason.allCases.compactMap { reason in
            let count = items.filter { $0.reason == reason }.count
            return count > 0 ? (reason, count) : nil
        }
    }

    private func message(_ text: String) -> some View {
        message(text) { EmptyView() }
    }

    private func message<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
    }
}

private struct PRRow: View {
    let pr: AttentionPR
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: pr.reason.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pr.reason.tint)
                    .frame(width: 14)
                Text(pr.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DroppySpacing.sm)
                Text(pr.shortReference)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
                Text(pr.updatedAt.compactAge)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .frame(width: 26, alignment: .trailing)
            }
            .padding(.horizontal, DroppySpacing.xsm)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                    .fill(isHovered ? AdaptiveColors.notchSurfaceCardFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(pr.reason.label) · \(pr.repository)#\(pr.number) by \(pr.author)")
        .accessibilityLabel("\(pr.reason.label): \(pr.title), \(pr.shortReference)")
    }
}

private extension Date {
    /// `now`, `12m`, `3h`, `5d`, `8w`.
    var compactAge: String {
        let seconds = max(0, Date().timeIntervalSince(self))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 7)))w"
        }
    }
}

// MARK: - HUD

/// New pull request alerts go through `host.hud`; the conformance tells the
/// validator, the Store listing and the harness that HUDs are part of this
/// droplet.
extension GithubprsDroplet: HUDPresenting {}

// MARK: - Settings pane

extension GithubprsDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(GithubprsSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "GitHub token", keywords: ["github", "token", "pull request", "review"]),
            SettingsSearchEntry(title: "Repositories", keywords: ["repository", "organization", "owner", "filter", "scope"]),
            SettingsSearchEntry(title: "Alert on new pull requests", keywords: ["alert", "notification", "hud", "notch"]),
            SettingsSearchEntry(title: "Refresh interval", keywords: ["refresh", "interval"]),
            SettingsSearchEntry(title: "Include draft pull requests", keywords: ["draft"]),
            SettingsSearchEntry(title: "Keyboard shortcut", keywords: ["shortcut", "hotkey", "open"]),
        ]
    }
}

private struct GithubprsSettings: View {
    @ObservedObject var droplet: GithubprsDroplet
    @State private var draft = ""
    @State private var scopeDraft = ""
    @State private var scopeInvalid = false

    private var intervalBinding: Binding<Double> {
        let minutes = droplet.binding(GithubprsDroplet.Keys.interval) { droplet.refreshMinutes }
        return Binding(get: { Double(minutes.wrappedValue) }, set: { minutes.wrappedValue = Int($0.rounded()) })
    }

    var body: some View {
        DropletSettingsPane {
            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("GitHub account")
                    Text("A fine-grained token with read-only access to pull requests, commit statuses and contents is safest. A classic token needs the repo and read:org scopes, which also allow writes. It is stored in your Keychain.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    if droplet.hasToken {
                        DropletControlRow(title: "Token", icon: "key.fill") {
                            Button("Remove") { droplet.removeToken() }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        DropletControlRow(title: "Token", icon: "key") {
                            HStack(spacing: DroppySpacing.sm) {
                                SecureField("Token", text: $draft, prompt: Text("ghp_…"))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                                    .onSubmit(save)
                                Button("Save", action: save)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                    if case .failed(let error) = droplet.status {
                        DropletControlRow(title: "Last refresh", icon: "exclamationmark.triangle") {
                            Text(error)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                                .help(error)
                        }
                    } else if let updated = droplet.lastUpdated {
                        DropletControlRow(title: "Last refresh") {
                            DropletValuePill(text: updated.formatted(date: .omitted, time: .shortened))
                        }
                    }
                }
            }

            DropletSettingsSection {
                VStack(alignment: .leading, spacing: 2) {
                    settingsSectionHeader("Repositories")
                    Text("Only show pull requests from these organizations, accounts or repositories. Leave it empty to include all of GitHub.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } content: {
                DropletSettingsCard {
                    ForEach(droplet.scopes, id: \.self) { scope in
                        DropletControlRow(title: scope, icon: scope.contains("/") ? "book.closed" : "building.2") {
                            Button("Remove") { droplet.removeScope(scope) }
                                .buttonStyle(.bordered)
                        }
                    }
                    DropletControlRow(title: droplet.scopes.isEmpty ? "Add a filter" : "Add another", icon: "plus") {
                        HStack(spacing: DroppySpacing.sm) {
                            TextField("Filter", text: $scopeDraft, prompt: Text("owner or owner/repo"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onSubmit(addScope)
                                .onChange(of: scopeDraft) { _, _ in scopeInvalid = false }
                            Button("Add", action: addScope)
                                .buttonStyle(.bordered)
                                .disabled(scopeDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if scopeInvalid {
                        DropletControlRow(title: "Use owner or owner/repo", icon: "exclamationmark.triangle") { EmptyView() }
                    }
                    DropletToggleRow(
                        title: "Show every open pull request",
                        subtitle: "Also list pull requests other people opened in these repositories, even when nothing is asked of you. Needs at least one filter.",
                        isOn: droplet.binding(GithubprsDroplet.Keys.includeOthers) { droplet.includeOthers }
                    )
                    .disabled(droplet.scopes.isEmpty)
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("List")
            } content: {
                DropletSettingsCard {
                    DropletSliderRow(
                        title: "Refresh every",
                        value: "\(droplet.refreshMinutes) min",
                        binding: intervalBinding,
                        range: 1...30,
                        step: 1
                    )
                    DropletToggleRow(
                        title: "Include draft pull requests",
                        subtitle: "Show review requests on drafts, and flag problems on your own drafts.",
                        isOn: droplet.binding(GithubprsDroplet.Keys.includeDrafts) { droplet.includeDrafts }
                    )
                    DropletToggleRow(
                        title: "Include assigned pull requests",
                        subtitle: "Show pull requests other people opened and assigned to you.",
                        isOn: droplet.binding(GithubprsDroplet.Keys.includeAssigned) { droplet.includeAssigned }
                    )
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Alerts and shortcut")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Alert on new pull requests",
                        subtitle: "Shows a notch alert when a pull request you did not open appears: a new review request, an assignment, or a new pull request in a repository you watch.",
                        isOn: droplet.binding(GithubprsDroplet.Keys.alertsEnabled) { droplet.alertsEnabled }
                    )
                    DropletControlRow(
                        title: "Keyboard shortcut",
                        infoTip: "Opens the shelf on this widget, and closes it when it is already showing. Suggested: Control-Option-Command-G."
                    ) {
                        Button("Change…") { droplet.openShortcuts() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func addScope() {
        if droplet.addScope(scopeDraft) {
            scopeDraft = ""
        } else {
            scopeInvalid = true
        }
    }

    private func save() {
        droplet.saveToken(draft)
        draft = ""
    }
}
