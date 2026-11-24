//
//  GithubprsHarness.swift
//
//  Run with: droppykit run
//
//  GITHUBPRS_DEMO=1 droppykit run   every surface filled with the sample rows
//  GITHUB_TOKEN=… droppykit run     your real pull requests, without saving a token
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import DroppyKit
import DroppyKitHarness
import Foundation
import Githubprs

@main
struct GithubprsHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet {
        let environment = ProcessInfo.processInfo.environment
        if environment["GITHUBPRS_DEMO"] == "1" {
            return GithubprsDroplet(seed: .items(GithubprsDroplet.sampleItems))
        }
        if let token = environment["GITHUB_TOKEN"], !token.isEmpty {
            return GithubprsDroplet(seed: .token(token))
        }
        return GithubprsDroplet()
    }
}
