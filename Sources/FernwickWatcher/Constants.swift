// SPDX-License-Identifier: Apache-2.0
// Register constants the cover layer uses (register section 5), by their register names.
// Values marked "proposal" are set by a hands-on test later; none here is measured end to end.
import Foundation

public enum Register {
    /// `VIDEO_VOTE`: a covered region lifts only after this many clean judgements in a row of the same
    /// region, video or still (SD-230). As built.
    public static let VIDEO_VOTE = 4
    /// `TIME_TO_COVER`: 0.5 s, the mark for one new picture on an otherwise still screen. Proposal (ST-031).
    public static let TIME_TO_COVER: TimeInterval = 0.5
    /// `FULL_REJUDGE` for show-first: every window is re-judged in full at least this often. Proposal (ST-038).
    public static let FULL_REJUDGE_SHOW_FIRST: TimeInterval = 30
    /// `JUDGEMENT_BUDGET`: sustained model judgements per second, shared equally among displays. Proposal (ST-038).
    public static let JUDGEMENT_BUDGET: Double = 40
    /// `DETECTOR_CALL_CAP`: at most this many judgements in one call. As built.
    public static let DETECTOR_CALL_CAP = 400
    /// `JUDGEMENT_BURST`: the bucket depth. Not yet set by the register (ST-038); the working value is
    /// `DETECTOR_CALL_CAP`, so one full call can always be afforded from a full bucket.
    public static let JUDGEMENT_BURST: Double = Double(DETECTOR_CALL_CAP)
    /// `DISPLAYS_MAX`: judged displays the watcher handles inside its memory budget. Proposal: two on an
    /// 8 GB Mac (ST-039). Displays beyond it are covered whole.
    public static let DISPLAYS_MAX = 2
    /// How long judging may stall on one frame before the display is covered whole (step 3 of
    /// "slowness covers more"). Not in the register; a working value for step 1, tied to ST-038.
    public static let JUDGING_STALL: TimeInterval = 5
}
