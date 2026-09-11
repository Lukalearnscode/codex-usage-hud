import Foundation
import os
import CodexUsageHUDCore

final class AppServerClient: @unchecked Sendable {
    // Overridable only so the stall-recovery path can be exercised against a
    // stub that accepts requests and never answers them. Production always
    // takes the default.
    private let executablePath = ProcessInfo.processInfo
        .environment["CODEX_HUD_APP_SERVER_PATH"] ?? "/Applications/ChatGPT.app/Contents/Resources/codex"
    private let logger = Logger(subsystem: "com.local.CodexUsageHUD", category: "app-server")
    private let retryDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    var onSnapshot: ((RateLimitSnapshot) -> Void)?
    var onStatus: ((AppServerClientStatus) -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var rateLimitRequestIDs = Set<Int>()
    private var readInFlight = false
    private var refreshPending = false
    private var initialized = false
    private var inputBuffer = Data()
    private var stopped = false
    private var readTimeoutWorkItem: DispatchWorkItem?
    // A rate-limit request that is never answered leaves readInFlight set, and
    // every later refresh then collapses into refreshPending and returns. The
    // process stays alive, so terminationHandler never fires and the HUD keeps
    // showing a stale number with no sign anything is wrong. Time the request
    // out and rebuild the connection instead.
    // Overridable so the timeout path itself can be exercised end to end
    // instead of only being read.
    private let readTimeout: TimeInterval = ProcessInfo.processInfo
        .environment["CODEX_HUD_READ_TIMEOUT"].flatMap(TimeInterval.init) ?? 15

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        cancelReadTimeout()
        // On the way out there is no later turn of the run loop to escalate
        // from, so the wait has to be synchronous here or the child would
        // outlive us. Blocking briefly is harmless while quitting.
        closeProcess(terminate: true, waitForExit: true)
    }

    func refresh() {
        guard !stopped else { return }
        if initialized, let process, process.isRunning {
            requestRateLimits()
        } else {
            connect()
        }
    }

    private func connect() {
        guard !stopped else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeProcess(terminate: true)
        initialized = false
        readInFlight = false
        refreshPending = false
        cancelReadTimeout()
        inputBuffer.removeAll(keepingCapacity: true)
        notify(.connecting)

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            logger.error("Codex app-server executable is unavailable")
            notify(.unavailable)
            scheduleReconnect()
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                DispatchQueue.main.async { self?.handleEndOfStream() }
                return
            }
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleTermination() }
        }

        self.process = process
        inputPipe = input
        outputPipe = output

        do {
            try process.run()
            sendInitialize()
        } catch {
            logger.error("Unable to launch Codex app-server")
            closeProcess(terminate: false)
            notify(.unavailable)
            scheduleReconnect()
        }
    }

    private func sendInitialize() {
        let requestID = allocateRequestID()
        initializeRequestID = requestID
        send([
            "method": "initialize",
            "id": requestID,
            "params": [
                "clientInfo": [
                    "name": "codex_usage_hud",
                    "title": "Codex Usage HUD",
                    "version": "0.1.0"
                ]
            ]
        ])
    }

    private func requestRateLimits() {
        guard initialized else { return }
        if readInFlight {
            refreshPending = true
            return
        }
        let requestID = allocateRequestID()
        rateLimitRequestIDs.insert(requestID)
        readInFlight = true
        startReadTimeout()
        send(["method": "account/rateLimits/read", "id": requestID])
    }

    private func startReadTimeout() {
        cancelReadTimeout()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.readTimeoutWorkItem = nil
                self.handleReadTimeout()
            }
        }
        readTimeoutWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + readTimeout, execute: work)
    }

    private func cancelReadTimeout() {
        readTimeoutWorkItem?.cancel()
        readTimeoutWorkItem = nil
    }

    private func handleReadTimeout() {
        guard readInFlight else { return }
        logger.error("Rate-limit request timed out; rebuilding the app-server connection")
        initialized = false
        readInFlight = false
        refreshPending = false
        rateLimitRequestIDs.removeAll()
        // closeProcess clears terminationHandler, so this cannot double-schedule
        // a reconnect with handleTermination.
        closeProcess(terminate: true)
        notify(.unavailable)
        scheduleReconnect()
    }

    private func send(_ object: [String: Any]) {
        guard let inputPipe, process?.isRunning == true else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            logger.error("Unable to write to Codex app-server")
            handleTermination()
        }
    }

    private func receive(_ data: Data) {
        inputBuffer.append(data)
        while let newline = inputBuffer.firstIndex(of: 0x0A) {
            let line = inputBuffer.prefix(upTo: newline)
            inputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any]
            else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String,
           method == "account/rateLimits/updated" {
            requestRateLimits()
            return
        }

        guard let requestID = (message["id"] as? NSNumber)?.intValue else { return }
        if requestID == initializeRequestID {
            initializeRequestID = nil
            guard message["error"] == nil else {
                notify(.unavailable)
                return
            }
            initialized = true
            reconnectAttempt = 0
            send(["method": "initialized", "params": [:]])
            requestRateLimits()
            return
        }

        guard rateLimitRequestIDs.remove(requestID) != nil else { return }
        readInFlight = false
        cancelReadTimeout()
        if message["error"] != nil {
            notify(isAuthenticationError(message) ? .notAuthenticated : .unavailable)
            requestPendingRefreshIfNeeded()
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            notify(.unavailable)
            requestPendingRefreshIfNeeded()
            return
        }
        switch RateLimitParser.parse(data) {
        case let .snapshot(snapshot):
            reconnectAttempt = 0
            onSnapshot?(snapshot)
            notify(.available)
        case .notAuthenticated:
            notify(.notAuthenticated)
        case .invalid:
            // The branch that hid a lapsed subscription for six days
            // (2026-09-11): a well-formed reply with no window the parser
            // recognised, and nothing in the log to say so.
            logger.error("Rate-limit reply parsed but carried no usable window")
            notify(.unavailable)
        }
        requestPendingRefreshIfNeeded()
    }

    private func requestPendingRefreshIfNeeded() {
        guard refreshPending else { return }
        refreshPending = false
        requestRateLimits()
    }

    private func isAuthenticationError(_ message: [String: Any]) -> Bool {
        guard let error = message["error"] as? [String: Any],
              let text = error["message"] as? String else { return false }
        let lowercased = text.lowercased()
        return lowercased.contains("auth") || lowercased.contains("login") || lowercased.contains("unauthorized")
    }

    private func handleEndOfStream() {
        guard process?.isRunning != true else { return }
        handleTermination()
    }

    private func handleTermination() {
        guard !stopped else { return }
        initialized = false
        readInFlight = false
        cancelReadTimeout()
        closeProcess(terminate: false)
        notify(.unavailable)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, reconnectWorkItem == nil else { return }
        let index = Swift.min(reconnectAttempt, retryDelays.count - 1)
        let delay = retryDelays[index]
        reconnectAttempt = Swift.min(reconnectAttempt + 1, retryDelays.count - 1)
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.reconnectWorkItem = nil
                self.connect()
            }
        }
        reconnectWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func escalateNow(_ process: Process, graceSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(graceSeconds)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private func allocateRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func notify(_ status: AppServerClientStatus) {
        onStatus?(status)
    }

    private func closeProcess(terminate: Bool, waitForExit: Bool = false) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if terminate, let running = process, running.isRunning {
            running.terminate()
            // terminate() only requests an exit. Escalate to SIGKILL so an
            // unresponsive app-server cannot survive as an orphan.
            if waitForExit {
                Self.escalateNow(running, graceSeconds: 1)
            } else {
                // While the app keeps running, escalate off the main thread so
                // the HUD never freezes the way waitUntilExit would.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    guard running.isRunning else { return }
                    kill(running.processIdentifier, SIGKILL)
                }
            }
        }
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
    }
}
