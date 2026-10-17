import DSHProtocol
import Foundation
import XCTest

final class JSONValueTests: XCTestCase {
    func testIntegerConversionPreservesTruncationTowardZero() {
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
        XCTAssertEqual(JSONValue.number(42.75).intValue, 42)
        XCTAssertEqual(JSONValue.number(-42.75).intValue, -42)
        XCTAssertEqual(JSONValue.number(-0.75).intValue, 0)
        XCTAssertNil(JSONValue.string("42").intValue)
        XCTAssertNil(JSONValue.null.intValue)
    }

    func testIntegerConversionRejectsNonfiniteAndOutOfRangeNumbers() throws {
        for value: Double in [.infinity, -.infinity, .nan, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            XCTAssertNil(JSONValue.number(value).intValue)
        }
        let remote = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"seq":1e100,"turn":-1e100}"#.utf8))
        XCTAssertNil(remote["seq"]?.intValue)
        XCTAssertNil(remote["turn"]?.intValue)
    }

    func testIntegerConversionHandlesNativeIntegerBounds() throws {
        XCTAssertEqual(JSONValue.number(Double(Int.min)).intValue, Int.min)
        XCTAssertNil(JSONValue.number(Double(Int.min).nextDown).intValue)
        let upper = try JSONDecoder().decode(Double.self, from: Data(String(Int.max).utf8))
        if let exactlyRepresented = Int(exactly: upper) {
            XCTAssertEqual(JSONValue.number(upper).intValue, exactlyRepresented)
        } else {
            // On 64-bit platforms Double(Int.max) rounds up to 2^63.
            XCTAssertNil(JSONValue.number(upper).intValue)
            XCTAssertEqual(JSONValue.number(upper.nextDown).intValue, Int.max - 1_023)
        }
        XCTAssertNil(JSONValue.number(upper * 2).intValue)
    }

    func testNestedJSONRoundTripsWithoutLosingUnknownFields() throws {
        let original: JSONValue = [
            "kind": "future-event", "enabled": true, "count": 7,
            "nested": ["values": [nil, "text", 1.5]],
        ]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), original)
        XCTAssertEqual(original["nested"]?["values"]?[2]?.doubleValue, 1.5)
    }
}
