import Darwin
import DSHKit
import Foundation

/// Read-only smoke test: connects to the local host and prints its model catalog.
/// It does not create a session, send a prompt, or invoke a model.
@main
struct ModelCatalogExample {
    static func main() async {
        let connection = DSHConnection()
        var failed = false
        do {
            let client = try await connection.client()
            let catalog = try await client.modelCatalog()
            for group in catalog.groups {
                print(group.name)
                for model in group.models {
                    print("  \(model.id): \(model.name)")
                }
            }
        } catch {
            failed = true
            // Avoid printing arbitrary host payloads or authenticated URLs.
            FileHandle.standardError.write(Data((DSHConnectionError.message(for: error) + "\n").utf8))
        }
        await connection.disconnect()
        if failed { exit(EXIT_FAILURE) }
    }
}
