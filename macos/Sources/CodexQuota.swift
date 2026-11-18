import Foundation
import CoreFoundation
import Darwin

/// Account quota is shared across devices. Transcript token_count records are historical,
/// may belong to another login, and must never stand in for a current account response.
enum CodexQuota {
  enum Failure: Error { case missingCLI, unavailable, timeout }

  static func sample(_ result: [String: Any], now: Date = Date()) -> QuotaSample? {
    let bucket: [String: Any]?
    if let groups = result["rateLimitsByLimitId"] as? [String: Any] {
      // A model-specific bucket must not be presented as the general Codex allowance.
      bucket = groups["codex"] as? [String: Any]
    } else {
      bucket = result["rateLimits"] as? [String: Any]
    }
    guard let bucket, (bucket["limitId"] as? String ?? "codex") == "codex" else { return nil }
    let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
      guard let w = bucket[key] as? [String: Any],
        let used = w["usedPercent"] as? NSNumber, CFGetTypeID(used) != CFBooleanGetTypeID(),
        used.doubleValue.isFinite,
        let duration = w["windowDurationMins"] as? NSNumber,
        CFGetTypeID(duration) != CFBooleanGetTypeID(),
        let reset = w["resetsAt"] as? NSNumber, CFGetTypeID(reset) != CFBooleanGetTypeID(),
        let window = QuotaWindow.read(
          percent: min(100, max(0, used.doubleValue)), minutes: duration.intValue,
          reset: reset.doubleValue), window.reset > now
      else { return nil }
      return window
    }
    guard !windows.isEmpty else { return nil }
    return QuotaSample(date: now, windows: windows, source: "codex-account")
  }

  static func binary() -> URL? {
    let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
    var candidates = [
      "/Applications/Codex.app/Contents/Resources/codex",
      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
      "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
      home.path + "/.local/bin/codex", home.path + "/.bun/bin/codex",
    ]
    candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":").map { String($0) + "/codex" }
    let nvm = home.appendingPathComponent(".nvm/versions/node")
    candidates += ((try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? [])
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
      .map { $0.appendingPathComponent("bin/codex").path }
    return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
  }

  /// A short-lived, read-only app-server request. No model turn or reset-credit redemption.
  /// Run on a utility queue; output is drained continuously and bounded to avoid pipe deadlocks.
  static func fetch(executable: URL? = binary(), timeout: TimeInterval = 12) -> Result<QuotaSample, Failure> {
    guard let executable else { return .failure(.missingCLI) }
    let proc = Process(), input = Pipe(), output = Pipe()
    let done = DispatchSemaphore(value: 0), lock = NSLock()
    var buffer = Data(), result: Result<QuotaSample, Failure>?, initialized = false
    proc.executableURL = executable; proc.arguments = ["app-server"]
    // npm installs use /usr/bin/env node; Finder-launched apps have a minimal PATH.
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = executable.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    proc.environment = env
    proc.standardInput = input; proc.standardOutput = output; proc.standardError = FileHandle.nullDevice
    func send(_ object: [String: Any]) throws {
      var data = try JSONSerialization.data(withJSONObject: object)
      data.append(10)
      try input.fileHandleForWriting.write(contentsOf: data)
    }
    // A child that exits while we write should be a failed request, never SIGPIPE in Perch.
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      lock.lock(); defer { lock.unlock() }
      guard result == nil else { return }
      if data.isEmpty { result = .failure(.unavailable); done.signal(); return }
      buffer.append(data)
      if buffer.count > 1_048_576 { result = .failure(.unavailable); done.signal(); return }
      while let end = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          let id = message["id"] as? Int else { continue }
        if id == 1 && !initialized {
          guard message["error"] == nil else { result = .failure(.unavailable); done.signal(); return }
          initialized = true
          do {
            try send(["method": "initialized"])
            try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
          } catch { result = .failure(.unavailable); done.signal(); return }
        } else if id == 2 {
          if message["error"] == nil, let payload = message["result"] as? [String: Any],
            let value = sample(payload) { result = .success(value) }
          else { result = .failure(.unavailable) }
          done.signal(); return
        }
      }
    }
    defer {
      output.fileHandleForReading.readabilityHandler = nil
      try? input.fileHandleForWriting.close()
      if proc.isRunning {
        proc.terminate()
        // Reap the short-lived server, including on timeout; do not leave background pollers.
        let deadline = Date().addingTimeInterval(0.5)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        proc.waitUntilExit()
      }
    }
    do {
      try proc.run()
      try send(["id": 1, "method": "initialize", "params": [
        "clientInfo": ["name": "perch", "version": "1"]]])
    } catch { return .failure(.unavailable) }
    let completed = done.wait(timeout: .now() + timeout) == .success
    lock.lock(); defer { lock.unlock() }
    return completed ? (result ?? .failure(.unavailable)) : .failure(.timeout)
  }
}
