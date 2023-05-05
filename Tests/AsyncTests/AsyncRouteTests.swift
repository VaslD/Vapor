import XCTVapor
import XCTest
import Vapor
import NIOHTTP1

final class AsyncRouteTests: XCTestCase {
    func testEnumResponse() throws {
        enum IntOrString: AsyncResponseEncodable {
            case int(Int)
            case string(String)

            func encodeResponse(for request: Request) async throws -> Response {
                switch self {
                case .int(let i):
                    return try await i.encodeResponse(for: request)
                case .string(let s):
                    return try await s.encodeResponse(for: request)
                }
            }
        }

        let app = Application(.testing)
        defer { app.shutdown() }

        app.routes.get("foo") { req -> IntOrString in
            if try req.query.get(String.self, at: "number") == "true" {
                return .int(42)
            } else {
                return .string("string")
            }
        }

        try app.testable().test(.GET, "/foo?number=true") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "42")
        }.test(.GET, "/foo?number=false") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "string")
        }
    }

    func testResponseEncodableStatus() throws {
        struct User: Content {
            var name: String
        }

        let app = Application(.testing)
        defer { app.shutdown() }

        app.post("users") { req async throws -> Response in
            return try await req.content
                .decode(User.self)
                .encodeResponse(status: .created, for: req)
        }

        try app.testable().test(.POST, "/users", beforeRequest: { req in
            try req.content.encode(["name": "vapor"], as: .json)
        }) { res in
            XCTAssertEqual(res.status, .created)
            XCTAssertEqual(res.headers.contentType, .json)
            XCTAssertEqual(res.body.string, """
            {"name":"vapor"}
            """)
        }
    }
}
