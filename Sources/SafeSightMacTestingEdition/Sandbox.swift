// SPDX-License-Identifier: Apache-2.0
// Whether the app runs inside macOS's App Sandbox. The Testing edition checks and covers only when it does: inside
// the sandbox, macOS itself stops it from writing anywhere but its own container, from using the network (it has
// no network entitlement) and from reaching other apps' data. A copy that finds itself outside (run with
// `swift run`, or a bundle not made by tools/make-app.sh --testing) shows why and does nothing else.
import Foundation

public enum Sandbox {
    /// True when both signs of the App Sandbox are there: macOS sets APP_SANDBOX_CONTAINER_ID for a sandboxed app,
    /// and gives it a home folder inside ~/Library/Containers.
    public static func isSandboxed(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: String = NSHomeDirectory()) -> Bool {
        guard let id = environment["APP_SANDBOX_CONTAINER_ID"], !id.isEmpty else { return false }
        return containerID(ofHome: home) != nil
    }

    /// The container's name when `home` is a sandbox container's Data folder (…/Library/Containers/<name>/Data),
    /// else nil.
    public static func containerID(ofHome home: String) -> String? {
        let parts = URL(fileURLWithPath: home).standardizedFileURL.pathComponents
        guard parts.count >= 5, parts[parts.count - 1] == "Data", parts[parts.count - 3] == "Containers",
              parts[parts.count - 4] == "Library" else { return nil }
        let id = parts[parts.count - 2]
        return id.isEmpty || id == "." || id == ".." ? nil : id
    }
}
