//
//  GitHubClient.swift
//  Githubprs
//

import Foundation

/// Why a pull request is on the list. The order is how the paired widget lists the counts.
public enum AttentionReason: Int, Comparable, Sendable, CaseIterable {
    /// Someone asked you, or a team you are on, to review it.
    case reviewRequested
    /// Your PR: a reviewer asked for changes.
    case changesRequested
    /// Your PR: checks are failing.
    case checksFailing
    /// Your PR: it conflicts with its base branch.
    case conflicts
    /// Your PR: approved and green, waiting for you to merge it.
    case readyToMerge
    /// Assigned to you, authored by someone else.
    case assigned
    /// Open in one of the watched repositories, nothing asked of you.
    case open

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .changesRequested: "Changes requested"
        case .checksFailing: "Checks failing"
        case .conflicts: "Merge conflicts"
        case .readyToMerge: "Ready to merge"
        case .assigned: "Assigned"
        case .open: "Open"
        }
    }

    /// Whether this reason asks something of you, as opposed to just being open.
    public var needsYou: Bool { self != .open }

    public var shortLabel: String {
        switch self {
        case .reviewRequested: "Review"
        case .changesRequested: "Changes"
        case .checksFailing: "Failing"
        case .conflicts: "Conflicts"
        case .readyToMerge: "Merge"
        case .assigned: "Assigned"
        case .open: "Open"
        }
    }

    public var systemImage: String {
        switch self {
        case .reviewRequested: "eye"
        case .changesRequested: "exclamationmark.bubble"
        case .checksFailing: "xmark.octagon"
        case .conflicts: "arrow.triangle.merge"
        case .readyToMerge: "checkmark.circle"
        case .assigned: "person.crop.circle"
        case .open: "arrow.triangle.pull"
        }
    }
}

/// One pull request that needs you.
public struct AttentionPR: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repository: String
    public let author: String
    public let updatedAt: Date
    public let reason: AttentionReason

    /// `owner/repo#123`, shortened to `repo#123`.
    public var shortReference: String {
        let repo = repository.split(separator: "/").last.map(String.init) ?? repository
        return "\(repo)#\(number)"
    }
}

public enum GitHubClientError: LocalizedError {
    case unauthorized
    case http(Int)
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub rejected the token"
        case .http(let code): "GitHub returned \(code)"
        case .api(let message): message
        }
    }
}

/// Asks GitHub's GraphQL API for the open pull requests that need the
/// token's owner, in one request.
struct GitHubClient {
    let token: String
    var session: URLSession = Self.ephemeralSession

    /// No disk cache and no cookie jar: responses carry private repository
    /// and pull request names, and nothing else in Droppy shares the session.
    private static let ephemeralSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    struct Options {
        var includeDrafts: Bool
        var includeAssigned: Bool
        /// Owners (`acme`) and repositories (`acme/platform`) to limit
        /// the search to. Empty means all of GitHub.
        var scopes: [String] = []
        /// Also list every other open PR in `scopes`. Ignored without scopes.
        var includeOthers: Bool = false

        /// GitHub ORs scope qualifiers, so `user:a repo:b/c` is either.
        /// `user:` matches organisations as well as personal accounts.
        var scopeQualifiers: String {
            scopes.map { $0.contains("/") ? "repo:\($0)" : "user:\($0)" }.joined(separator: " ")
        }

        var searchBase: String {
            ["is:pr is:open archived:false", scopeQualifiers].filter { !$0.isEmpty }.joined(separator: " ")
        }

        var showsOthers: Bool { includeOthers && !scopes.isEmpty }

        /// Changes whenever the set of PRs the search can return changes, so
        /// new-PR alerts start from a fresh baseline instead of firing for
        /// everything a widened filter brings in.
        var baselineSignature: String {
            let parts = [scopes.map { $0.lowercased() }.sorted().joined(separator: ","),
                         "\(includeDrafts)", "\(includeAssigned)", "\(showsOthers)"]
            return parts.joined(separator: "|")
        }

        /// The same set on github.com, for the "more" link.
        var webSearchURL: URL {
            var query = searchBase
            if !showsOthers { query += " involves:@me" }
            if !includeDrafts { query += " -is:draft" }
            var components = URLComponents(string: "https://github.com/pulls")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            return components.url!
        }

        /// Scope entries as the user types them: `owner` or `owner/repo`.
        static func normalizedScope(_ raw: String) -> String? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = value.range(of: "github.com/") { value = String(value[range.upperBound...]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
            else { return nil }
            return value
        }
    }

    func fetchAttention(options: Options) async throws -> [AttentionPR] {
        let draft = options.includeDrafts ? "" : " -is:draft"
        let base = options.searchBase
        var searches = [
            "review: search(query: \"\(base) review-requested:@me\(draft)\", type: ISSUE, first: 50) { nodes { ...pr } }",
            "mine: search(query: \"\(base) author:@me\", type: ISSUE, first: 50) { nodes { ...pr } }",
        ]
        if options.includeAssigned {
            searches.append("assigned: search(query: \"\(base) assignee:@me -author:@me\(draft)\", type: ISSUE, first: 50) { nodes { ...pr } }")
        }
        if options.showsOthers {
            searches.append("others: search(query: \"\(base) -author:@me\(draft)\", type: ISSUE, first: 50) { nodes { ...pr } }")
        }
        let query = """
        query {
          \(searches.joined(separator: "\n  "))
        }
        fragment pr on PullRequest {
          id number title url isDraft updatedAt reviewDecision mergeable
          author { login }
          repository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
        """

        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Droppy-GitHubPRs", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(["query": query])
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw GitHubClientError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw GitHubClientError.http(http.statusCode) }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Response.self, from: data)
        // A token that cannot see one of the scopes still gets data for the
        // rest, alongside an error; only a response with nothing in it is a
        // failure, and then GitHub's own message says why.
        let apiMessage = payload.errors?.first?.message ?? "Empty response from GitHub"
        guard let result = payload.data, result.hasAnySearch else {
            throw GitHubClientError.api(apiMessage)
        }

        var seen = Set<String>()
        var items: [AttentionPR] = []
        func add(_ node: Node, _ reason: AttentionReason) {
            guard seen.insert(node.id).inserted else { return }
            items.append(node.attention(reason))
        }

        result.review?.nodes.compactMap { $0 }.forEach { add($0, .reviewRequested) }
        for node in result.mine?.nodes.compactMap({ $0 }) ?? [] {
            if let reason = node.ownReason(includeDrafts: options.includeDrafts) { add(node, reason) }
        }
        result.assigned?.nodes.compactMap { $0 }.forEach { add($0, .assigned) }
        result.others?.nodes.compactMap { $0 }.forEach { add($0, .open) }

        // Most recently updated first; the reason glyph on each row says why.
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Wire format

    private struct Response: Decodable {
        let data: Result?
        let errors: [APIError]?
    }

    private struct APIError: Decodable { let message: String }

    private struct Result: Decodable {
        // Each alias is null on its own when GitHub fails that one search.
        let review: Search?
        let mine: Search?
        let assigned: Search?
        let others: Search?

        var hasAnySearch: Bool { review != nil || mine != nil || assigned != nil || others != nil }
    }

    private struct Search: Decodable { let nodes: [Node?] }

    private struct Node: Decodable {
        struct Login: Decodable { let login: String }
        struct Repo: Decodable { let nameWithOwner: String }
        struct Commits: Decodable { let nodes: [CommitNode] }
        struct CommitNode: Decodable { let commit: Commit }
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable { let state: String }

        let id: String
        let number: Int
        let title: String
        let url: URL
        let isDraft: Bool
        let updatedAt: Date
        let reviewDecision: String?
        let mergeable: String?
        let author: Login?
        let repository: Repo
        let commits: Commits

        var checkState: String? { commits.nodes.last?.commit.statusCheckRollup?.state }

        /// What, if anything, the author has to do next. `nil` means the PR
        /// is waiting on someone else.
        func ownReason(includeDrafts: Bool) -> AttentionReason? {
            if isDraft, !includeDrafts { return nil }
            if reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
            if checkState == "FAILURE" || checkState == "ERROR" { return .checksFailing }
            if mergeable == "CONFLICTING" { return .conflicts }
            if !isDraft, reviewDecision == "APPROVED", checkState == nil || checkState == "SUCCESS" {
                return .readyToMerge
            }
            return nil
        }

        func attention(_ reason: AttentionReason) -> AttentionPR {
            AttentionPR(
                id: id, number: number, title: title, url: url,
                repository: repository.nameWithOwner, author: author?.login ?? "ghost",
                updatedAt: updatedAt, reason: reason
            )
        }
    }
}
