// SPDX-License-Identifier: Apache-2.0
// Faults (chapter 05, sections 5.9 and 5.11; CONTRIBUTING rule 5). Every fault leads to more covering:
// a display that cannot be judged gets a whole-display cover. No fault ever locks the screen, logs
// anyone out, changes a setting or tells anyone. There is no code path here for any of those.
import SafeSightMacCore

/// Why a display cannot be judged right now. A closed list, so the repair card can say it plainly.
public enum FaultCause: String, Sendable, CaseIterable, Codable {
    /// ScreenCaptureKit gave no content list (most often: Screen Recording is off).
    case noPermissionOrNoContent
    /// No stream runs for an active display.
    case noStream
    /// A stream stopped with an error.
    case streamStopped
    /// A frame said "blank", "suspended" or "stopped".
    case frameNotJudgeable
    /// A frame's metadata was missing or unusable, so no trustworthy map exists.
    case badFrameMetadata
    /// The model files are missing or failed their hash check, or the detector could not load.
    case detectorUnavailable
    /// Judging has fallen too far behind (step 3 of "slowness covers more").
    case judgingBehind
    /// A display change, sleep or a session switch is in progress.
    case displayChanging
    /// More displays than `DISPLAYS_MAX` are active.
    case tooManyDisplays
    /// A new display has not had its first judged frame yet.
    case notYetJudged

    /// The plain words for the repair card (chapter 09 owns the final wording).
    public var plainWords: String {
        switch self {
        case .noPermissionOrNoContent: return "Screen Recording is off for \(AppText.productName), so this display cannot be checked."
        case .noStream: return "This display cannot be checked, so it stays covered."
        case .streamStopped: return "Checking this display stopped. \(AppText.productName) is trying again."
        case .frameNotJudgeable: return "This display is not sending pictures that can be checked."
        case .badFrameMetadata: return "This display sent a picture that could not be placed on screen."
        case .detectorUnavailable: return "The picture checker could not start. Its model files are missing or changed."
        case .judgingBehind: return "Checking has fallen behind, so this display is covered until it catches up."
        case .displayChanging: return "A display is changing. It is covered until it has been checked."
        case .tooManyDisplays: return "More displays are on than this version can check, so this one stays covered."
        case .notYetJudged: return "This display has not been checked yet."
        }
    }
}
