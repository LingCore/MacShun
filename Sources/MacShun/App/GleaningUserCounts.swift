// SPDX-License-Identifier: MIT

import Foundation
import Combine

final class GleaningUserCounts: ObservableObject {
    @Published var values: [String: Int] = [:]

    private struct Catalog: Decodable {
        struct Project: Decodable {
            struct Stats: Decodable { let users: Int? }
            let slug: String
            let stats: Stats?
        }
        let projects: [Project]
    }

    static func fetch() async throws -> [String: Int] {
        guard let url = InstallReport.serverURL(feed: UpdateFeed.defaultURL, path: "/api/v1/projects") else { return [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [String: Int] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var counts: [String: Int] = [:]
        for project in catalog.projects {
            if let count = project.stats?.users, count >= 0 {
                counts[project.slug] = count
            }
        }
        return counts
    }
}
