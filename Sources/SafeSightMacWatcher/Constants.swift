// SPDX-License-Identifier: Apache-2.0
// Register constants the cover layer uses (register section 5), by their register names.
// Values marked "proposal" are set by a hands-on test later; none here is measured end to end.
import Foundation

public enum Register {
    /// `VIDEO_VOTE`: a covered region lifts only after this many clean judgements in a row of the same
    /// region, video or still (SD-230). As built.
    public static let VIDEO_VOTE = 4
    /// `TIME_TO_COVER`: 0.5 s, the mark for one new picture on an otherwise still screen. Proposal (ST-031).
    /// It also stays the step-2 rule: a window left with unjudged entries this long is covered whole.
    public static let TIME_TO_COVER: TimeInterval = 0.5
    /// The owner's goal (18 November 2026), tighter than `TIME_TO_COVER`: about 0.1 s from a new picture to
    /// its cover. Not a register value. When judging a window's new pictures would take longer than this, they
    /// are blurred first and shown when cleared (cover first).
    public static let COVER_GOAL: TimeInterval = 0.1
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
    /// A cover whose window has gone from the window list stays where it last stood until that place is judged clean
    /// `VIDEO_VOTE` times, or until the window has been gone this long and the place has been judged clean
    /// `WINDOW_GONE_VOTE` times since it went (judgements from before it went never count). Not in the register;
    /// working values.
    public static let WINDOW_GONE: TimeInterval = 1
    public static let WINDOW_GONE_VOTE = 2
    /// How long one frame may be judged for (one `process` call). Parts of the frame not reached by then are blurred
    /// and judged in the next call, so one busy frame cannot hold up the other display's frames or leave new pictures
    /// sharp for long. Not in the register; a working value, tied to ST-038.
    public static let JUDGE_CALL_WALL: TimeInterval = 0.25
    /// A display's frame left waiting this long has its changed areas covered until it is judged (`TIME_TO_COVER`).
    public static let WAITING_FRAME_COVER: TimeInterval = TIME_TO_COVER
    /// How often the changed areas a frame reports are checked against its pixels (a comparison of every row outside
    /// them with the last frame's). Not in the register; a working value.
    public static let DIRTY_CHECK_EVERY: TimeInterval = 1
    /// After this many frames in a row judged slower than `COVER_GOAL` (from the first), the pictures in each new frame's
    /// changed parts are blurred before judging. Not in the register; a working value.
    public static let OVERRUN_FRAMES = 1
    /// A cover judged on its own and found flagged on a place that has not changed is judged again this often (a
    /// borderline place is not covered for good). Not in the register; a working value.
    public static let RECHECK_FLAGGED_EVERY: TimeInterval = 3
}
