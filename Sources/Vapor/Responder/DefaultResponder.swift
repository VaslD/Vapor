import Foundation
import RoutingKit
import NIOCore
import NIOHTTP1
import Logging

/// Vapor's main `Responder` type. Combines configured middleware + router to create a responder.
internal struct DefaultResponder: Responder {
    private let router: TrieRouter<CachedRoute>
    private let notFoundResponder: Responder

    private struct CachedRoute {
        let route: Route
        let responder: Responder
    }

    /// Creates a new `ApplicationResponder`
    public init(routes: Routes, middleware: [Middleware] = []) {
        let options = routes.caseInsensitive ?
            Set(arrayLiteral: TrieRouter<CachedRoute>.ConfigurationOption.caseInsensitive) : []
        let router = TrieRouter(CachedRoute.self, options: options)
        
        for route in routes.all {
            // Make a copy of the route to cache middleware chaining.
            let cached = CachedRoute(
                route: route,
                responder: middleware.makeResponder(chainingTo: route.responder)
            )
            // remove any empty path components
            let path = route.path.filter { component in
                switch component {
                case .constant(let string):
                    return string != ""
                default:
                    return true
                }
            }
            
            // If the route isn't explicitly a HEAD route,
            // and it's made up solely of .constant components,
            // register a HEAD route with the same path
            if route.method == .GET &&
                route.path.allSatisfy({ component in
                    if case .constant(_) = component { return true }
                    return false
            }) {
                let headRoute = Route(
                    method: .HEAD,
                    path: cached.route.path,
                    responder: middleware.makeResponder(chainingTo: HeadResponder()),
                    requestType: cached.route.requestType,
                    responseType: cached.route.responseType)

                let headCachedRoute = CachedRoute(route: headRoute, responder: middleware.makeResponder(chainingTo: HeadResponder()))

                router.register(headCachedRoute, at: [.constant(HTTPMethod.HEAD.string)] + path)
            }
            
            router.register(cached, at: [.constant(route.method.string)] + path)
        }
        self.router = router
        self.notFoundResponder = middleware.makeResponder(chainingTo: NotFoundResponder())
    }

    /// See `Responder`
    public func respond(to request: Request) -> EventLoopFuture<Response> {
        let response: EventLoopFuture<Response>
        if let cachedRoute = self.getRoute(for: request) {
            request.route = cachedRoute.route
            response = cachedRoute.responder.respond(to: request)
        } else {
            response = self.notFoundResponder.respond(to: request)
        }
        return response
    }
    
    /// Gets a `Route` from the underlying `TrieRouter`.
    private func getRoute(for request: Request) -> CachedRoute? {
        let pathComponents = request.url.path
            .split(separator: "/")
            .map(String.init)
        
        // If it's a HEAD request and a HEAD route exists, return that route...
        if request.method == .HEAD, let route = self.router.route(
            path: [HTTPMethod.HEAD.string] + pathComponents,
            parameters: &request.parameters
        ) {
            return route
        }

        // ...otherwise forward HEAD requests to GET route
        let method = (request.method == .HEAD) ? .GET : request.method
        
        return self.router.route(
            path: [method.string] + pathComponents,
            parameters: &request.parameters
        )
    }
}

private struct HeadResponder: Responder {
    func respond(to request: Request) -> EventLoopFuture<Response> {
        request.eventLoop.makeSucceededFuture(.init(status: .ok))
    }
}

private struct NotFoundResponder: Responder {
    func respond(to request: Request) -> EventLoopFuture<Response> {
        request.eventLoop.makeFailedFuture(RouteNotFound())
    }
}

struct RouteNotFound: Error {
    let stackTrace: StackTrace?

    init() {
        self.stackTrace = StackTrace.capture(skip: 1)
    }
}

extension RouteNotFound: AbortError {    
    var status: HTTPResponseStatus {
        .notFound
    }
}

extension RouteNotFound: DebuggableError {
    var logLevel: Logger.Level { 
        .debug
    }
}
