import Foundation

struct KarabinerConfiguration {
    static let variable = "screenveil_lock_expiration"
    static let condition = [
        "type": "expression_unless",
        "expression": "\(variable) > system.now.milliseconds"
    ]
    private static let directActions: Set<String> = ["shell_command", "software_function", "select_input_source"]
    private static let outputFields = ["to", "to_if_alone", "to_if_held_down", "to_after_key_up", "to_delayed_action"]

    let url: URL

    init(url: URL = Self.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let directory = xdg.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return directory.appendingPathComponent("karabiner/karabiner.json").resolvingSymlinksInPath()
    }

    struct Coverage {
        var guarded = 0
        var unguarded = 0
        var isEnabled: Bool { guarded > 0 }
    }

    func coverage() throws -> Coverage {
        try transform(Data(contentsOf: url), enable: nil).coverage
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> Coverage {
        let original = try Data(contentsOf: url)
        let result = try transform(original, enable: enabled)
        guard let changed = result.data else { return result.coverage }

        let manager = FileManager.default
        let backup = url.deletingLastPathComponent().appendingPathComponent("automatic_backups", isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backupURL = backup.appendingPathComponent("karabiner-screenveil-\(timestamp)-\(UUID().uuidString.prefix(8)).json")
        try manager.copyItem(at: url, to: backupURL)
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".screenveil-\(UUID().uuidString)")
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let mode = attributes[.posixPermissions] ?? 0o600
        guard manager.createFile(atPath: tempURL.path, contents: changed, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: tempURL) }
        guard try Data(contentsOf: url) == original else {
            throw ConfigurationError.changedDuringEdit
        }
        guard rename(tempURL.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return result.coverage
    }

    private func transform(_ input: Data, enable: Bool?) throws -> (coverage: Coverage, data: Data?) {
        guard var root = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              var profiles = root["profiles"] as? [[String: Any]] else {
            throw ConfigurationError.invalidConfiguration
        }
        var coverage = Coverage()
        var changed = false
        for profile in profiles.indices {
            guard var complex = profiles[profile]["complex_modifications"] as? [String: Any],
                  var rules = complex["rules"] as? [[String: Any]] else { continue }
            for rule in rules.indices {
                guard var manipulators = rules[rule]["manipulators"] as? [[String: Any]] else { continue }
                for index in manipulators.indices {
                    var manipulator = manipulators[index]
                    let direct = Self.outputFields.contains { Self.containsDirectAction(manipulator[$0]) }
                    var conditions = manipulator["conditions"] as? [[String: Any]] ?? []
                    let guarded = conditions.contains(where: Self.isOwnCondition)
                    if enable == true, direct, !guarded {
                        conditions.append(Self.condition)
                        manipulator["conditions"] = conditions
                        changed = true
                    } else if enable == false, guarded {
                        conditions.removeAll(where: Self.isOwnCondition)
                        if conditions.isEmpty { manipulator.removeValue(forKey: "conditions") }
                        else { manipulator["conditions"] = conditions }
                        changed = true
                    }
                    manipulators[index] = manipulator
                    if direct {
                        if conditions.contains(where: Self.isOwnCondition) { coverage.guarded += 1 }
                        else { coverage.unguarded += 1 }
                    }
                }
                rules[rule]["manipulators"] = manipulators
            }
            complex["rules"] = rules
            profiles[profile]["complex_modifications"] = complex
        }
        guard changed else { return (coverage, nil) }
        root["profiles"] = profiles
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        return (coverage, data)
    }

    private static func containsDirectAction(_ value: Any?) -> Bool {
        if let array = value as? [Any] { return array.contains { containsDirectAction($0) } }
        guard let object = value as? [String: Any] else { return false }
        return !directActions.isDisjoint(with: object.keys) || object.values.contains { containsDirectAction($0) }
    }

    private static func isOwnCondition(_ condition: [String: Any]) -> Bool {
        (condition as? [String: String]) == Self.condition
    }

    private enum ConfigurationError: LocalizedError {
        case changedDuringEdit, invalidConfiguration

        var errorDescription: String? {
            switch self {
            case .changedDuringEdit: return "Karabiner settings changed while ScreenVeil was saving. Try again."
            case .invalidConfiguration: return "The Karabiner configuration could not be read."
            }
        }
    }
}

final class KarabinerLease {
    static let executable = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: executable) }
    static let minimumVersion = "15.6.0"
    static let supportsConditions: Bool = {
        let appURL = URL(fileURLWithPath: "/Applications/Karabiner-Elements.app")
        guard let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return false }
        return version.compare(minimumVersion, options: .numeric) != .orderedAscending
    }()
    private let queue = DispatchQueue(label: "com.er1cg1ao.screenveil.karabiner")
    private static let lifetime: TimeInterval = 12

    func update(locked: Bool, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let success = Self.write(locked: locked)
            if let completion { DispatchQueue.main.async { completion(success) } }
        }
    }

    private static func write(locked: Bool) -> Bool {
        let expiration = locked ? Int64(Date().addingTimeInterval(lifetime).timeIntervalSince1970 * 1_000) : 0
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--set-variables", "{\"\(KarabinerConfiguration.variable)\":\(expiration)}"]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            guard finished.wait(timeout: .now() + 2) == .success else {
                if process.isRunning { process.terminate() }
                return false
            }
            // Some CLI connection failures report only on stderr.
            let diagnostic = errors.fileHandleForReading.availableData
            return process.terminationStatus == 0 && diagnostic.isEmpty
        } catch {
            return false
        }
    }
}
