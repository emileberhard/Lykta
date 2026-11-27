import Foundation
import LyktaCore
import Testing

@Test func keepingOnlyCopiesPathsPresentOnBothSides() throws {
    let decoder = JSONDecoder()
    let proposed = try decoder.decode(JSONValue.self, from: Data(#"{"nested":{"one":1,"stays":2},"items":[0,1]}"#.utf8))
    let current = try decoder.decode(JSONValue.self, from: Data(#"{"nested":{"one":9,"missing":3},"items":[7,8]}"#.utf8))
    let expected = try decoder.decode(JSONValue.self, from: Data(#"{"nested":{"one":9,"stays":2},"items":[0,8]}"#.utf8))
    #expect(proposed.keeping(["nested.one", "items.1", "nested.missing", "nested.stays"], from: current) == expected)
}
