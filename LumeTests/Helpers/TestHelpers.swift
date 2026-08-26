import Foundation
@testable import Lume
import SwiftData

func makeTestContainer() throws -> ModelContainer {
    let schema = Schema([
        Playlist.self,
        Lume.Category.self,
        LiveStream.self,
        Movie.self,
        Series.self,
        Episode.self,
        CastMember.self,
        EPGListing.self,
        EPGSource.self
    ])
    // `cloudKitDatabase: .none` is required: the catalog uses `@Attribute(.unique)`,
    // which CloudKit forbids. The default `.automatic` mirrors to CloudKit on a
    // signed/entitled test host and fails the load with `loadIssueModelContainer`.
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return try ModelContainer(for: schema, configurations: [config])
}

func exampleDataURL(_ filename: String, filePath: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: filePath)
    while url.lastPathComponent != "LumeTests", url.lastPathComponent != "LumeUITests" {
        url.deleteLastPathComponent()
    }
    url.deleteLastPathComponent()
    return url.appendingPathComponent("ExampleData/\(filename)")
}

func loadExampleJSON<T: Decodable>(_ filename: String, filePath: String = #filePath) throws -> T {
    let url = exampleDataURL(filename, filePath: filePath)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: data)
}

/// Two-configuration in-memory container: the local catalog plus the CloudKit
/// mirror's models, matching the app's split containers.
///
/// Both configurations pin `cloudKitDatabase: .none`: the catalog uses
/// `@Attribute(.unique)`, which CloudKit forbids, so the default `.automatic`
/// fails the load with `loadIssueModelContainer` on an entitled simulator host.
func makeProfileTestContainer() throws -> ModelContainer {
    let catalogModels: [any PersistentModel.Type] = [
        Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
        Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
    ]
    let cloudModels: [any PersistentModel.Type] = [
        SyncedPlaylist.self, UserContentState.self, UserProfile.self, SyncedEPGSource.self,
        SyncedParentalPIN.self, SyncedCategoryRestriction.self
    ]
    let localConfig = ModelConfiguration(
        "local",
        schema: Schema(catalogModels),
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    let cloudConfig = ModelConfiguration(
        "cloud",
        schema: Schema(cloudModels),
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    return try ModelContainer(
        for: Schema(catalogModels + cloudModels),
        configurations: localConfig, cloudConfig
    )
}
