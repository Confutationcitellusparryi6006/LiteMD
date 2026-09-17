import Foundation
@testable import LiteMDDomain
import Testing

@Suite("Folder appearance")
struct FolderAppearanceTests {
    @Test func presetsAreComplete() {
        #expect(FolderColor.allCases.count == 8)
        #expect(FolderSymbol.allCases.count == 24)
        #expect(Set(FolderSymbol.allCases.map(\.systemName)).count == 24)
    }

    @Test func defaultAppearanceIsNotStored() {
        var map = FolderAppearanceMap()
        let folder = URL(fileURLWithPath: "/notes/Work")
        map.set(FolderAppearance(color: .red, symbol: .work), for: folder)
        #expect(map.appearance(for: URL(fileURLWithPath: "/notes/Work/"))?.color == .red)
        map.set(FolderAppearance(symbol: .folder), for: folder)
        #expect(map.entries.isEmpty)
    }

    @Test func renamesAndMovesCarryDescendants() {
        var map = FolderAppearanceMap()
        map.set(FolderAppearance(color: .blue), for: URL(fileURLWithPath: "/notes/Work"))
        map.set(FolderAppearance(symbol: .code), for: URL(fileURLWithPath: "/notes/Work/Code"))
        map.set(FolderAppearance(color: .green), for: URL(fileURLWithPath: "/notes/Workshop"))

        map.itemMoved(from: URL(fileURLWithPath: "/notes/Work"), to: URL(fileURLWithPath: "/notes/Archive/Job"))
        #expect(map.appearance(for: URL(fileURLWithPath: "/notes/Archive/Job"))?.color == .blue)
        #expect(map.appearance(for: URL(fileURLWithPath: "/notes/Archive/Job/Code"))?.symbol == .code)
        // 前缀相同但不是子目录的文件夹不受影响。
        #expect(map.appearance(for: URL(fileURLWithPath: "/notes/Workshop"))?.color == .green)
        #expect(map.appearance(for: URL(fileURLWithPath: "/notes/Work")) == nil)

        map.itemRemoved(at: URL(fileURLWithPath: "/notes/Archive"))
        #expect(map.entries.count == 1)
    }

    @Test func roundTripsThroughJSON() throws {
        var map = FolderAppearanceMap()
        map.set(FolderAppearance(color: .purple, symbol: .ideas, tintsName: true), for: URL(fileURLWithPath: "/notes/Ideas"))
        let decoded = try JSONDecoder().decode(FolderAppearanceMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
    }
}
