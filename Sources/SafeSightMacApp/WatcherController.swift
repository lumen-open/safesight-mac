// SPDX-License-Identifier: Apache-2.0
// The watcher, glued together. Capture streams feed a frame queue; one serial judging queue runs the detector and
// the cover layer, one frame at a time with every display in turn; the main thread decides what every display shows
// and draws it (CoverCoordinator: a canvas for every display the OS lists, covered whole until judged, and every
// display covered the moment macOS announces a change). In the practice state there is no keeper, no shield, no
// heartbeat and no fault ladder (SD-223 (d)). Faults cover more; nothing here can lock the screen, log anyone out
// or send anything. For the Testing edition it also carries the edition's line to the covers and the repair card,
// lets the emergency quit take every cover down at once, and tells the stall watchdog whether a cover is up.
import AppKit
import DetectorCore
import SafeSightMacCapture
import SafeSightMacCover
import SafeSightMacWatcher
import Foundation

final class WatcherController: CaptureSink, @unchecked Sendable {
    // Capture queues, the judging queue and the main thread.
    private let frames = FrameQueue()

    // Judging queue only.
    private let judgeQueue = DispatchQueue(label: "safesightmac.judge", qos: .userInitiated)
    private var detector: Detector?
    private var pipelines: [UInt32: DisplayPipeline] = [:]
    /// The judged displays, counted on the main thread from the OS's display lists.
    private var judgedIDs: [UInt32] = []
    /// Per display: the stream generation its frames must have (raised by every display change).
    private var required: [UInt32: Int] = [:]

    // Main thread only.
    /// The presenter the coordinator draws with, watched for the stall watchdog.
    private let presenter: WatchedPresenter
    private let coordinator: CoverCoordinator
    /// Capture requests and reports between the coordinator and the stream scheduler (ready once the detector is).
    private let link: CaptureLink
    private var busySince: [UInt32: TimeInterval] = [:]
    private var wholeSince: TimeInterval?
    private(set) var detectorFailed = false
    private(set) var running = false
    private let repairCard: RepairCard
    private var timer: Timer?
    var onChange: (() -> Void)?
    /// Told whether any cover may be up: before every drawing, and after it (the Testing edition's stall watchdog).
    @MainActor var onCoversShown: ((Bool) -> Void)? {
        get { presenter.onCoversShown }
        set { presenter.onCoversShown = newValue }
    }
    var repairActions: RepairCard.Actions?
    /// What every display shows now: one plan per display the OS lists.
    @MainActor var plans: [CoverPlan] { coordinator.shown }

    let ownPID = getpid()

    @MainActor init(presenter: CoverPresenter) {
        self.repairCard = RepairCard()
        let watched = WatchedPresenter(presenter)
        self.presenter = watched
        let c = CoverCoordinator(presenter: watched, generations: GenerationCounter())
        self.coordinator = c
        // The link sets the coordinator's capture requests: every request carries a generation taken on this thread.
        self.link = CaptureLink(coordinator: c)
        coordinator.judging = { [weak self] judged, required in
            self?.judgeQueue.async { self?.setJudging(judged, required) }
        }
        coordinator.onShown = { [weak self] _ in self?.shownChanged() }
        coordinator.wake = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01) { MainActor.assumeIsolated { self?.tick() } }
        }
    }

    /// The models folder: `SAFESIGHTMAC_MODELS`, else the app's own Resources/models (the shipped place in
    /// the practice state, SD-223 (b)), else models/local in the working folder. The Testing edition reads its
    /// models only from inside itself.
    static func modelsFolder() -> URL {
        #if SAFESIGHTMAC_TESTING
        return Bundle.main.resourceURL?.appendingPathComponent("models") ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/models")
        #else
        if let p = ProcessInfo.processInfo.environment["SAFESIGHTMAC_MODELS"] { return URL(fileURLWithPath: p) }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("models"), FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models/local")
        #endif
    }

    /// What the covers and the repair card carry besides the way out (the Testing edition's line).
    @MainActor var notice: CoverNotice? {
        get { presenter.notice }
        set { presenter.notice = newValue; repairCard.notice = newValue; coordinator.present(urgent: true) }
    }

    /// Waits, at most `timeout` seconds, for the judging queue to finish what it is doing. True when it did.
    func waitForJudging(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        judgeQueue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Takes every cover and the repair card off the screen at once, without stopping anything (the emergency quit
    /// does this just before the app ends).
    @MainActor func hideEverything() {
        presenter.removeAll()
        repairCard.hide()
    }

    // MARK: Start, stop

    /// Covers every display whole at once, before any stream exists; loads the detector; then starts capture.
    @MainActor func start(rule: DetectorRule) {
        guard !running else { return }
        running = true
        detectorFailed = false
        frames.open()
        coordinator.start()
        link.attach(ScreenCaptureBackend(sink: self, ownPID: ownPID))
        startTimer()
        loadDetector(rule: rule)
        onChange?()
    }

    /// Stops capture and removes every cover. Used for Pause (practice state only) and Quit.
    @MainActor func stop() {
        running = false
        frames.close()
        // Not waited for: anything the old streams still send carries a generation outranked when covering starts again.
        link.detach()
        judgeQueue.async { [weak self] in
            self?.pipelines.values.forEach { $0.reset() }
            self?.pipelines = [:]
        }
        timer?.invalidate(); timer = nil
        coordinator.stop()
        busySince = [:]; wholeSince = nil
        repairCard.hide()
        onChange?()
    }

    /// Try again: every display stays covered whole while capture (and the detector, if it failed) starts again.
    /// Unlike stopping and starting, no cover comes down in between.
    @MainActor func restart(rule: DetectorRule) {
        guard running else { start(rule: rule); return }
        detectorFailed = false
        busySince = [:]
        coordinator.restart()
        loadDetector(rule: rule)
        onChange?()
    }

    /// macOS announced a display change: every display is covered whole now, before the change is applied.
    @MainActor func displaysWillChange() { coordinator.willChange(.change) }

    /// A display change has been applied: the displays are read again, each is covered whole until judged, and capture
    /// restarts once the change has settled.
    @MainActor func displaysDidChange() { coordinator.didChange(.change) }

    /// The Mac or its displays are going to sleep, or the session is going away: every display is covered whole until
    /// `resume` with the same reason.
    @MainActor func suspend(_ reason: HoldReason) { coordinator.willChange(reason) }

    /// The Mac or its displays woke, or the session came back: as a display change, for that reason.
    @MainActor func resume(_ reason: HoldReason) { coordinator.didChange(reason) }

    func setRule(_ rule: DetectorRule) { judgeQueue.async { [weak self] in self?.detector?.setRule(rule) } }

    @MainActor private func loadDetector(rule: DetectorRule) {
        link.ready = false
        judgeQueue.async { [weak self] in
            guard let self else { return }
            if self.detector == nil {
                do { self.detector = try WatcherModels.loadDetector(folder: Self.modelsFolder(), rule: rule) }
                catch { DispatchQueue.main.async { self.reportDetectorFailure() }; return }
            } else {
                self.detector?.setRule(rule)
            }
            DispatchQueue.main.async {
                guard self.running else { return }
                self.link.ready = true
                self.coordinator.restartNow()
            }
        }
    }

    @MainActor private func reportDetectorFailure() {
        guard running else { return }
        detectorFailed = true
        coordinator.detectorFailed()
        onChange?()
    }

    // MARK: CaptureSink (capture queues)

    func capture(_ frame: CapturedFrame) {
        if frames.offer(frame, now: ProcessInfo.processInfo.systemUptime) {
            judgeQueue.async { [weak self] in self?.judgeNext() }
        }
    }

    // MARK: Judging queue

    /// The judged displays and each display's required generation, from the main thread. A display whose generation
    /// was raised is covered whole until a frame of a new stream is judged; displays no longer judged are dropped.
    private func setJudging(_ judged: [UInt32], _ required: [UInt32: Int]) {
        judgedIDs = judged
        self.required = required
        let share = Register.JUDGEMENT_BUDGET / Double(max(1, judged.count))
        pipelines = pipelines.filter { judged.contains($0.key) }
        for (id, p) in pipelines {
            p.setBudgetShare(share)
            if let r = required[id], r > p.requiredGeneration { p.cover(because: .displayChanging, until: r) }
        }
    }

    /// Judges one frame, then lets every other display, and any other work waiting, have its turn.
    private func judgeNext() {
        guard let f = frames.next() else { return }
        judge(f)
        judgeQueue.async { [weak self] in self?.judgeNext() }
    }

    private func judge(_ f: CapturedFrame) {
        let id = f.display.id
        // Only judged displays, and only frames of a stream started since the display's last change.
        guard let det = detector, judgedIDs.contains(id), let need = required[id], f.generation >= need else { return }
        let p: DisplayPipeline
        if let existing = pipelines[id] {
            p = existing
        } else {
            p = DisplayPipeline(display: f.display, judger: det, budgetShare: Register.JUDGEMENT_BUDGET / Double(max(1, judgedIDs.count)),
                                ignoredPIDs: [ownPID])
            p.cover(because: .notYetJudged, until: need)
            pipelines[id] = p
        }
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { self.busySince[id] = start }
        // Plans handed out before judging ends (moved covers, cover-first blurs, fast flags) are drawn at once.
        // The pointer, in global points: the window under it and the pictures nearest it go first.
        let pointer = CGEvent(source: nil)?.location
        let generation = f.generation
        let plan = p.process(f, snapshot: WindowList.snapshot(), now: start, pointer: pointer) { [weak self] early in
            DispatchQueue.main.async { self?.coordinator.deliver(early, generation: generation) }
        }
        DispatchQueue.main.async {
            self.busySince[id] = nil
            self.coordinator.deliver(plan, generation: generation)
        }
    }

    // MARK: Main thread

    /// Four times a second: judging that stalls on one frame, or frames left waiting, cover that display whole until
    /// it catches up (step 3 of "slowness covers more"); what is due runs; and the OS's display lists are read again,
    /// so a display change nobody announced is covered too.
    @MainActor private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    @MainActor private func tick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var stalled = Set(busySince.filter { now - $0.value > Register.JUDGING_STALL }.keys)
        for (id, waited) in frames.waiting(now: now) where waited > Register.JUDGING_STALL { stalled.insert(id) }
        coordinator.tick(stalled: stalled)
        updateRepairCard(now: now)
    }

    @MainActor private func shownChanged() {
        updateRepairCard(now: ProcessInfo.processInfo.systemUptime)
        onChange?()
    }

    /// The repair card: whenever a display has been covered whole for two seconds or more. It sits on a display
    /// that is covered whole, never on one the owner is working on.
    @MainActor private func updateRepairCard(now: TimeInterval) {
        let causes = coordinator.shown.compactMap(\.wholeDisplay)
        if causes.isEmpty { wholeSince = nil } else if wholeSince == nil { wholeSince = now }
        if running, let s = wholeSince, now - s >= 2, let actions = repairActions {
            let covered = coordinator.shown.filter { $0.wholeDisplay != nil }.map(\.display.id).sorted()
            repairCard.show(causes: causes.sorted { $0 == .notYetJudged ? false : $1 == .notYetJudged }, actions: actions,
                            on: RepairCard.display(covered: covered, main: CGMainDisplayID()))
        } else {
            repairCard.hide()
        }
    }
}

/// The presenter the coordinator draws with, watched for the Testing edition's stall watchdog: it is told before
/// every drawing whether a cover may be up (so a hang while drawing counts), and after it whether one is; it is
/// disarmed only once no cover is left.
@MainActor
final class WatchedPresenter: CoverPresenter {
    private let inner: CoverPresenter
    private var showing = false
    var onCoversShown: ((Bool) -> Void)?

    init(_ inner: CoverPresenter) { self.inner = inner }

    var notice: CoverNotice? {
        get { inner.notice }
        set { inner.notice = newValue }
    }

    func apply(_ plans: [CoverPlan]) {
        let now = plans.contains { $0.wholeDisplay != nil || !$0.items.isEmpty }
        if now || showing { onCoversShown?(true) }
        inner.apply(plans)
        showing = now
        onCoversShown?(now)
    }

    func removeAll() {
        inner.removeAll()
        showing = false
        onCoversShown?(false)
    }
}
