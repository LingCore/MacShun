// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MacShun

@Suite("官网反馈页地址")
struct FeedbackURLTests {
    private let system = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

    private func items(_ url: URL?) -> [String: String] {
        let query = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    }

    @Test func httpsFeedKeepsHost() {
        let feed = URL(string: "https://lcstp.com/updates/macshun/stable.json?platform=macos&arch=arm64&osVersion=14.5.0")
        let url = InstallReport.feedbackURL(feed: feed, version: "0.3.0", system: system)
        #expect(url?.scheme == "https")
        #expect(url?.host == "lcstp.com")
        #expect(url?.path == "/projects/macshun/feedback")
        #expect(url?.fragment == nil)
        let query = items(url)
        #expect(query["version"] == "0.3.0")
        #expect(query["platform"] == "macos")
        #expect(query["arch"] == UpdateFeed.runtimeArch)
        #expect(query["osVersion"] == "14.5.0")
        #expect(query.count == 4)
    }

    @Test func loopbackFeedKeepsPort() {
        let feed = URL(string: "http://127.0.0.1:8787/updates/macshun/stable.json")
        let url = InstallReport.feedbackURL(feed: feed, version: "0.3.0", system: system)
        #expect(url?.absoluteString.hasPrefix("http://127.0.0.1:8787/projects/macshun/feedback?") == true)
    }

    @Test func missingVersionIsOmitted() {
        let url = InstallReport.feedbackURL(feed: UpdateFeed.defaultURL, version: nil, system: system)
        #expect(items(url)["version"] == nil)
        #expect(items(url)["platform"] == "macos")
    }

    @Test func invalidFeedFallsBackToProjectOrigin() {
        let remoteHTTP = URL(string: "http://example.com/updates/macshun/stable.json")
        for feed in [remoteHTTP, URL(string: "ftp://lcstp.com/x"), nil] {
            let url = InstallReport.feedbackURL(feed: feed, version: "0.3.0", system: system)
            #expect(url?.host == "lcstp.com")
            #expect(url?.path == "/projects/macshun/feedback")
            #expect(url?.fragment == nil)
            #expect(items(url)["version"] == "0.3.0")
        }
    }

    @Test func noValidOriginGivesNil() {
        let bad = URL(string: "http://example.com/x")
        #expect(InstallReport.feedbackURL(feed: bad, fallback: bad, version: "0.3.0", system: system) == nil)
        #expect(InstallReport.feedbackURL(feed: nil, fallback: nil, version: "0.3.0", system: system) == nil)
    }

    @Test func defaultFeedExample() {
        let url = InstallReport.feedbackURL(feed: UpdateFeed.url(UpdateFeed.defaultURL.absoluteString), version: "0.3.0", system: system)
        #expect(url?.absoluteString == "https://lcstp.com/projects/macshun/feedback?version=0.3.0&platform=macos&arch=\(UpdateFeed.runtimeArch)&osVersion=14.5.0")
    }
}
