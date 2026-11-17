import Foundation
@preconcurrency import Network

actor OAuthCallbackServer {
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timeout: Task<Void, Never>?
    private let state: String
    private var requestedPort: UInt16 = 0
    private var connections: [UUID: NWConnection] = [:]

    init(state: String) { self.state = state }

    func start(port: UInt16 = 0) async throws -> UInt16 {
        requestedPort = port
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await self?.finish(.failure(SpotifyError.authorizationTimeout))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                listener.start(queue: DispatchQueue(label: "app.albumer.oauth"))
            }
        } onCancel: { Task { await self.cancel() } }
    }

    func waitForCode() async throws -> String {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback = $0 }
        } onCancel: { Task { await self.cancel() } }
    }

    func cancel() { finish(.failure(SpotifyError.authorizationCancelled)) }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            startup?.resume(returning: port); startup = nil
        case .failed(let error):
            finish(.failure(error == .posix(.EADDRINUSE) ? SpotifyError.callbackPortUnavailable(requestedPort) : error))
        case .waiting(.posix(.EADDRINUSE)):
            finish(.failure(SpotifyError.callbackPortUnavailable(requestedPort)))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: DispatchQueue(label: "app.albumer.oauth.connection"))
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { await self?.received(data, complete: complete, error: error, connection: connection, id: id, buffer: buffer) }
        }
    }

    private func received(_ data: Data?, complete: Bool, error: NWError?, connection: NWConnection, id: UUID, buffer: Data) {
        let buffer = buffer + (data ?? Data())
        guard error == nil, buffer.count <= 8192 else { connection.cancel(); connections[id] = nil; return }
        guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
            if complete { connection.cancel(); connections[id] = nil }
            else { receive(connection, id: id, buffer: buffer) }
            return
        }
        let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/callback?") else {
            respond(connection, id: id, status: "404 Not Found", body: "Not found", result: nil); return
        }
        let result = Result { try PKCE.callbackCode(target: String(parts[1]), expectedState: state) }
        let succeeded = (try? result.get()) != nil
        respond(connection, id: id, status: succeeded ? "200 OK" : "400 Bad Request",
                body: succeeded ? "已连接 Spotify。可以关闭此页面，返回 Albumer。" : "连接未完成。请返回 Albumer 重试。", result: result)
    }

    private func respond(_ connection: NWConnection, id: UUID, status: String, body: String, result: Result<String, Error>?) {
        let html = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>Albumer</title><body style='background:#111313;color:#eee;font:17px system-ui;padding:12vh 10vw'><h1 style='font-weight:500'>Albumer</h1><p>\(body)</p></body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { await self?.responded(id: id, result: result) }
        })
    }
    private func responded(id: UUID, result: Result<String, Error>?) {
        connections[id] = nil
        if let result { finish(result) }
    }
    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let startup {
            switch result {
            case .failure(let error): startup.resume(throwing: error)
            case .success: startup.resume(throwing: SpotifyError.invalidResponse)
            }
        }
        startup = nil
        callback?.resume(with: result); callback = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
    }
}

