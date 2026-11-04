import Foundation

/// Names for sync-pipeline failures the UI and notification scheduler observe.
extension Notification.Name {
    /// Posted when any API request returns 401. Listener clears UI state and
    /// schedules a local notification telling the user to log in again.
    static let healthSyncAuthExpired = Notification.Name("healthSyncAuthExpired")

    /// Posted when a sync attempt fails for any non-401 reason. The
    /// userInfo `"error"` key carries the originating `Error` description.
    static let healthSyncFailed = Notification.Name("healthSyncFailed")
}

/// URLSession wrapper for communicating with the Rust Axum API.
actor APIClient {
    static let shared = APIClient()

    /// Base URL of the API server. Configure this in settings.
    var baseURL = URL(string: "https://health.lolzlab.com")!

    private static let tokenAccount = "api_jwt_token"
    private static let deviceIdAccount = "api_device_id"

    /// JWT token obtained after login/register. Persisted in the Keychain.
    var token: String? {
        didSet {
            if let token {
                KeychainStore.save(token, for: Self.tokenAccount)
            } else {
                KeychainStore.delete(Self.tokenAccount)
            }
        }
    }

    /// Device ID obtained after device registration. Persisted in the Keychain.
    var deviceId: UUID? {
        didSet {
            if let id = deviceId {
                KeychainStore.save(id.uuidString, for: Self.deviceIdAccount)
            } else {
                KeychainStore.delete(Self.deviceIdAccount)
            }
        }
    }

    private init() {
        // One-time migration from the legacy UserDefaults storage.
        let defaults = UserDefaults.standard
        if let legacyToken = defaults.string(forKey: "api_jwt_token") {
            KeychainStore.save(legacyToken, for: Self.tokenAccount)
            defaults.removeObject(forKey: "api_jwt_token")
        }
        if let legacyDevice = defaults.string(forKey: "api_device_id") {
            KeychainStore.save(legacyDevice, for: Self.deviceIdAccount)
            defaults.removeObject(forKey: "api_device_id")
        }

        self.token = KeychainStore.load(Self.tokenAccount)
        if let idStr = KeychainStore.load(Self.deviceIdAccount) {
            self.deviceId = UUID(uuidString: idStr)
        }
    }

    func setBaseURL(_ url: URL) {
        self.baseURL = url
    }

    func clearAuth() {
        self.token = nil
        self.deviceId = nil
    }

    func setDeviceId(_ id: UUID) {
        self.deviceId = id
    }

    /// Dedicated session so a stuck request doesn't tie up `URLSession.shared`
    /// (used by system traffic). Hash-check queries against the multi-million-
    /// row TimescaleDB hypertable can legitimately take 30–90 s under
    /// concurrent load on the Pi5 host, so the per-request budget is 120 s.
    /// Still under the 300 s server-side `statement_timeout` so the client
    /// surfaces a clean timeout before the API does.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Auth

    struct AuthRequest: Codable {
        let email: String
        let password: String
    }

    struct AuthResponse: Codable {
        let token: String
        let userId: UUID

        enum CodingKeys: String, CodingKey {
            case token
            case userId = "user_id"
        }
    }

    func register(email: String, password: String) async throws -> AuthResponse {
        let body = AuthRequest(email: email, password: password)
        let response: AuthResponse = try await post(path: "/auth/register", body: body)
        self.token = response.token
        return response
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        let body = AuthRequest(email: email, password: password)
        let response: AuthResponse = try await post(path: "/auth/login", body: body)
        self.token = response.token
        return response
    }

    // MARK: - Device Registration

    func registerDevice(_ registration: DeviceRegistration) async throws -> DeviceResponse {
        try await post(path: "/api/v1/devices/register", body: registration)
    }

    // MARK: - Hash Check (two-phase sync)

    func checkHashes(_ request: HashCheckRequest) async throws -> HashCheckResponse {
        try await post(path: "/api/v1/health/check", body: request)
    }

    // MARK: - Sync

    func syncHealth(_ payload: SyncPayload) async throws -> SyncResponse {
        try await post(path: "/api/v1/health/sync", body: payload)
    }

    // MARK: - Workout Routes

    func syncWorkoutRoutes(_ payload: WorkoutRoutePayload) async throws {
        let _: RouteResponse = try await post(path: "/api/v1/health/workout-routes", body: payload)
    }

    // MARK: - Voice Meal Logging

    func parseMeal(text: String, mealType: String) async throws -> MealNutritionResponse {
        let body = MealParseRequest(text: text, mealType: mealType)
        do {
            let response: MealNutritionResponse =
                try await post(path: "/api/meals/parse", body: body)
            // Any queued meals from offline attempts get flushed on the first
            // successful online request.
            await PendingMealQueue.shared.drain(apiClient: self)
            return response
        } catch {
            if Self.isNetworkError(error) {
                await PendingMealQueue.shared.enqueue(.init(
                    text: text, mealType: mealType, createdAt: Date()
                ))
            }
            throw error
        }
    }

    func mealHistory(limit: Int = 50, before: Date? = nil) async throws -> MealHistoryResponse {
        var components = URLComponents()
        components.path = "/api/meals/history"
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            items.append(URLQueryItem(
                name: "before",
                value: ISO8601DateFormatter().string(from: before)
            ))
        }
        components.queryItems = items
        guard let url = components.url(relativeTo: baseURL) else {
            throw APIError.invalidResponse
        }
        return try await getAt(url: url)
    }

    /// True for errors raised when the request never left the device (offline,
    /// DNS failure, TLS handshake abort). 5xx responses are *not* counted here
    /// — those come through as `APIError.server`.
    static func isNetworkError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
        ].contains(ns.code)
    }

    // MARK: - Delete

    func deleteSamples(_ uuids: [String]) async throws {
        let body = DeleteRequest(hkUuids: uuids)
        let _: DeleteResponse = try await post(path: "/api/v1/health/delete", body: body)
    }

    // MARK: - HTTP

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            print("API FAIL: POST \(path) status=\(http.statusCode) body=\(message.prefix(500))")
            if http.statusCode == 401 {
                // Single auth-expired path: clear credentials here so the
                // next request doesn't reuse a dead token, and broadcast so
                // the UI + notification scheduler can react. SyncEngine no
                // longer needs its own 401 branch.
                self.clearAuth()
                NotificationCenter.default.post(name: .healthSyncAuthExpired, object: nil)
            }
            throw APIError.server(statusCode: http.statusCode, message: message)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary>"
            print("API DECODE FAIL: POST \(path) error=\(error) bodyPreview=\(preview)")
            throw error
        }
    }

    private func get<Response: Decodable>(path: String) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidResponse
        }
        return try await getAt(url: url)
    }

    private func getAt<Response: Decodable>(url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            if http.statusCode == 401 {
                self.clearAuth()
                NotificationCenter.default.post(name: .healthSyncAuthExpired, object: nil)
            }
            throw APIError.server(statusCode: http.statusCode, message: message)
        }
        return try decoder.decode(Response.self, from: data)
    }
}

/// Response from the delete endpoint.
private struct DeleteResponse: Decodable {
    let deleted: Int
}

/// Response from the workout routes endpoint.
private struct RouteResponse: Decodable {
    let pointsSynced: Int
    enum CodingKeys: String, CodingKey {
        case pointsSynced = "points_synced"
    }
}

enum APIError: Error, LocalizedError {
    case invalidResponse
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .server(let code, let message):
            return "Server error \(code): \(message)"
        }
    }
}
