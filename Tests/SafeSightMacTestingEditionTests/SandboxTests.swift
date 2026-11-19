// SPDX-License-Identifier: Apache-2.0
// The Testing edition checks and covers only inside the App Sandbox: both signs of it must be there.
import Foundation
import Testing
@testable import SafeSightMacTestingEdition

@Suite struct SandboxTests {
    @Test(arguments: [
        ("/Users/a/Library/Containers/org.example.safesightmac.testing/Data", "org.example.safesightmac.testing"),
        ("/Users/a/Library/Containers/org.example.safesightmac.testing/Data/", "org.example.safesightmac.testing"),
        ("/Users/a/Library/Containers/0B1C9E1A-4C2B-4A39-9C21-3F0E0D7A6B11/Data", "0B1C9E1A-4C2B-4A39-9C21-3F0E0D7A6B11"),
    ])
    func aContainersDataFolderIsRecognised(_ home: String, _ id: String) {
        #expect(Sandbox.containerID(ofHome: home) == id)
    }

    @Test(arguments: ["/Users/a", "/Users/a/Library/Containers", "/Users/a/Library/Containers/Data",
                      "/Users/a/Library/Containers/x/Data/Library", "/Users/a/Library/Containers/x/../Data", "/", ""])
    func anythingElseIsNotAContainer(_ home: String) {
        #expect(Sandbox.containerID(ofHome: home) == nil)
    }

    @Test func bothSignsAreNeeded() {
        let home = "/Users/a/Library/Containers/org.example.safesightmac.testing/Data"
        let env = ["APP_SANDBOX_CONTAINER_ID": "org.example.safesightmac.testing"]
        #expect(Sandbox.isSandboxed(environment: env, home: home))
        #expect(!Sandbox.isSandboxed(environment: [:], home: home), "a container-like home alone is not enough")
        #expect(!Sandbox.isSandboxed(environment: env, home: "/Users/a"), "the variable alone is not enough")
        #expect(!Sandbox.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": ""], home: home))
    }

    @Test func thisTestRunIsNotSandboxed() {
        // So a Testing edition run like this (`swift run`) would check and cover nothing.
        #expect(!Sandbox.isSandboxed())
    }
}
