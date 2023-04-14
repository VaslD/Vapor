extension Request {
    /// Helper for accessing authenticated objects.
    /// See `Authenticator` for more information.
    public var auth: Authentication {
        return .init(request: self)
    }

    /// Request helper for storing and fetching authenticated objects.
    public struct Authentication: Sendable {
        let request: Request
        init(request: Request) {
            self.request = request
        }
    }
}

extension Request.Authentication {
    /// Authenticates the supplied instance for this request.
    public func login<A>(_ instance: A)
        where A: Authenticatable
    {
        self.cache[A.self] = instance
    }

    /// Unauthenticates an authenticatable type.
    public func logout<A>(_ type: A.Type = A.self)
        where A: Authenticatable
    {
        self.cache[A.self] = nil
    }

    /// Returns an instance of the supplied type. Throws if no
    /// instance of that type has been authenticated or if there
    /// was a problem.
    @discardableResult public func require<A>(_ type: A.Type = A.self) throws -> A
        where A: Authenticatable
    {
        guard let a = self.get(A.self) else {
            throw Abort(.unauthorized)
        }
        return a
    }

    /// Returns the authenticated instance of the supplied type.
    /// - note: `nil` if no type has been authed.
    public func get<A>(_ type: A.Type = A.self) -> A?
        where A: Authenticatable
    {
        return self.cache[A.self]
    }

    /// Returns `true` if the type has been authenticated.
    public func has<A>(_ type: A.Type = A.self) -> Bool
        where A: Authenticatable
    {
        return self.get(A.self) != nil
    }

    private final class Cache {
        private var storage: [ObjectIdentifier: Any]

        init() {
            self.storage = [:]
        }

        internal subscript<A>(_ type: A.Type) -> A?
            where A: Authenticatable
            {
            get { return storage[ObjectIdentifier(A.self)] as? A }
            set { storage[ObjectIdentifier(A.self)] = newValue }
        }
    }

    private struct CacheKey: Sendable, StorageKey {
        typealias Value = Cache
    }

    private var cache: Cache {
        get {
            if let existing = self.request.storage[CacheKey.self] {
                return existing
            } else {
                let new = Cache()
                self.request.storage[CacheKey.self] = new
                return new
            }
        }
        set {
            self.request.storage[CacheKey.self] = newValue
        }
    }
}
