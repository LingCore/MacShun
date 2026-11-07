// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MacShun

@Suite("匿名装机报告")
struct InstallReportTests {
    private func defaults() -> UserDefaults {
        let name = "InstallReportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let endpoint = URL(string: "https://lcstp.com/api/v1/projects/macshun/installs")!
    private let payload = InstallReport.payload(machine: "TEST-UUID", version: "0.3.0")

    private func date(_ day: Int) -> Date {
        var c = DateComponents(year: 2026, month: 10, day: day, hour: 12)
        c.calendar = Calendar(identifier: .gregorian)
        return c.date!
    }

    @Test func installID() {
        // printf %s 'gleaning.install.v1:macshun:TEST-UUID' | shasum -a 256
        let id = InstallReport.installID(machine: "TEST-UUID")
        #expect(id == "353216af4d6c516e6a80ab10216ae7d5652dd0ec6df7824960c51b19bef28ae4")
        #expect(id.count == 64)
        #expect(id.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(id != InstallReport.installID(machine: "OTHER"))
    }

    @Test func endpointFollowsFeed() {
        let https = URL(string: "https://lcstp.com/updates/macshun/stable.json?platform=macos&arch=arm64")
        #expect(InstallReport.endpoint(feed: https)?.absoluteString == "https://lcstp.com/api/v1/projects/macshun/installs")
        let local = URL(string: "http://127.0.0.1:8787/updates/macshun/stable.json")
        #expect(InstallReport.endpoint(feed: local)?.absoluteString == "http://127.0.0.1:8787/api/v1/projects/macshun/installs")
        #expect(InstallReport.endpoint(feed: URL(string: "http://example.com/updates/macshun/stable.json")) == nil)
        #expect(InstallReport.endpoint(feed: URL(string: "ftp://lcstp.com/x")) == nil)
        #expect(InstallReport.endpoint(feed: nil) == nil)
    }

    @Test func versionMustBeSemver() {
        #expect(InstallReport.isValidVersion("0.3.0"))
        #expect(InstallReport.isValidVersion("1.3.0-beta.1"))
        #expect(!InstallReport.isValidVersion("0.3"))
        #expect(!InstallReport.isValidVersion("v0.3.0"))
        #expect(!InstallReport.isValidVersion("0"))
        #expect(!InstallReport.isValidVersion("开发版"))
    }

    @Test func payloadKeys() throws {
        let data = try #require(InstallReport.encode(payload))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(Set(object.keys) == ["installId", "version", "platform", "arch", "osVersion"])
        #expect(object["platform"] == "macos")
        #expect(["arm64", "x64"].contains(object["arch"]))
        #expect(object["version"] == "0.3.0")
        #expect(object["osVersion"]?.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil)
        #expect(data.count < 1024)
    }

    @Test func sendsOncePerDay() async {
        let defaults = defaults()
        var calls = 0
        func run(_ day: Int) async -> Bool {
            await InstallReport.reportIfDue(defaults: defaults, now: date(day), endpoint: endpoint, payload: { payload }) { _, _ in calls += 1 }
        }
        #expect(await run(5))
        #expect(!(await run(5)))
        #expect(calls == 1)
        #expect(await run(6))
        #expect(calls == 2)
    }

    @Test func disabledSendsNothing() async {
        let defaults = defaults()
        defaults.set(false, forKey: InstallReport.enabledKey)
        var calls = 0
        let sent = await InstallReport.reportIfDue(defaults: defaults, endpoint: endpoint, payload: { payload }) { _, _ in calls += 1 }
        #expect(!sent)
        #expect(calls == 0)
        #expect(defaults.string(forKey: InstallReport.lastDayKey) == nil)
    }

    @Test func enabledByDefault() {
        #expect(InstallReport.isEnabled(defaults()))
    }

    @Test func attemptIsRecordedBeforeSending() async {
        let defaults = defaults()
        var recorded: String?
        await InstallReport.reportIfDue(defaults: defaults, now: date(5), endpoint: endpoint, payload: { payload }) { _, _ in
            recorded = defaults.string(forKey: InstallReport.lastDayKey)
        }
        #expect(recorded == InstallReport.dayString(date(5)))
    }

    @Test func missingEndpointOrPayloadSendsNothing() async {
        let defaults = defaults()
        var calls = 0
        await InstallReport.reportIfDue(defaults: defaults, endpoint: nil, payload: { payload }) { _, _ in calls += 1 }
        await InstallReport.reportIfDue(defaults: defaults, endpoint: endpoint, payload: { nil }) { _, _ in calls += 1 }
        #expect(calls == 0)
    }
}
