import Foundation

@main
struct ValidateModels {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try decoder.decode(PresenceSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        precondition(snapshot.profile.id == 6103235693)
        precondition(snapshot.history.count > 0)
        precondition(snapshot.heatmap.count == 7)
        precondition(snapshot.day.onlineSeconds >= 0)
        print("Server JSON model validation passed")
    }
}
