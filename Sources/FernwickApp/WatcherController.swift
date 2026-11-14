// SPDX-License-Identifier: Apache-2.0
// The watcher, glued together: capture streams feed one mailbox per display; one serial judging queue
// runs the detector and the cover layer; the main thread draws. In the practice state there is no
// keeper, no shield, no heartbeat and no fault ladder (SD-223 (d)). Faults cover more; nothing here
// can lock the screen, log anyone out or send anything.
import AppKit
import DetectorCore
import FernwickCapture
import FernwickCover
import FernwickWatcher
import Foundation

final class WatcherController: CaptureSink, @unchecked Sendable {
    // Guarded by `lock` (touched from the capture queues).
    private let lock = NSLock()
    private var mailboxes: [UInt32: FrameMailbox] = [:]
    private var scheduled: Set<UInt32> = []
    private var accepting = false

    // Judging queue only.
    private let judgeQueue = DispatchQueue(label: "fernwick.judge", qos: .userInitiated)
    private var detector: Detector?
    private var pipelines: [UInt32: DisplayPipeline] = [:]
    private var order: [UInt32] = []

    // Main thread only.
    private(set) var plans: [UInt32: CoverPlan] = [:]
    private var busySince: [UInt32: TimeInterval] = [:]
    private var wholeSince: TimeInterval?
    private(set) var detectorFailed = false
    private(set) var running = false
    private let presenter: CoverPresenter
    private let repairCard: RepairCard
    private var capture: ScreenCapture?
    private var watchdog: Timer?
    var onChange: (() -> Void)?
    var repairActions: RepairCard.Actions?

    let ownPID = getpid()

    @MainActor init(presenter: CoverPresenter) {
        self.presenter = presenter
        self.repairCard = RepairCard()
    }

    /// The models folder: `FERNWICK_MODELS`, else the app's own Resources/models (the shipped place in
    /// the practice state, SD-223 (b)), else models/local in the working folder.
    static func modelsFolder() -> URL {
        if let p = ProcessInfo.processInfo.environment["FERNWICK_MODELS"] { return URL(fileURLWithPath: p) }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("models"), FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models/local")
    }

    // MARK: Start, stop

    @MainActor func start(rule: DetectorRule) {
        guard !running else { return }
        running = true
        detectorFailed = false
        let cap = ScreenCapture(sink: self, ownPID: ownPID)
        capture = cap
        lock.withLock { accepting = true }
        startWatchdog()
        judgeQueue.async { [weak self] in
            guard let self else { return }
            if self.detector == nil {
                do { self.detector = try WatcherModels.loadDetector(folder: Self.modelsFolder(), rule: rule) }
                catch { self.reportDetectorFailure(); return }
            } else {
                self.detector?.setRule(rule)
            }
            Task { await cap.start() }
        }
        onChange?()
    }

    /// Stops capture and removes every cover. Used for Pause (practice state only) and Quit.
    @MainActor func stop() {
        running = false
        lock.withLock { accepting = false; mailboxes = [:] }
        let cap = capture
        capture = nil
        Task { await cap?.stop() }
        judgeQueue.async { [weak self] in
            self?.pipelines.values.forEach { $0.reset() }
            self?.pipelines = [:]
            DispatchQueue.main.async { self?.plans = [:]; self?.present() }
        }
        watchdog?.invalidate(); watchdog = nil
        presenter.removeAll()
        repairCard.hide()
        onChange?()
    }

    /// Covers every display whole, then rebuilds the streams (display change, wake, session return).
    @MainActor func rebuild(because cause: FaultCause) {
        guard running else { return }
        judgeQueue.async { [weak self] in
            guard let self else { return }
            let covered = self.pipelines.mapValues { $0.cover(because: cause) }
            DispatchQueue.main.async { self.plans.merge(covered) { $1 }; self.present() }
            let cap = self.capture
            Task { await cap?.start() }
        }
    }

    /// Covers every display whole without rebuilding (sleep, session switched away).
    @MainActor func coverAll(because cause: FaultCause) {
        judgeQueue.async { [weak self] in
            guard let self else { return }
            let covered = self.pipelines.mapValues { $0.cover(because: cause) }
            DispatchQueue.main.async { self.plans.merge(covered) { $1 }; self.present() }
        }
    }

    func setRule(_ rule: DetectorRule) { judgeQueue.async { [weak self] in self?.detector?.setRule(rule) } }

    private func reportDetectorFailure() {
        let ids = ScreenCapture.activeDisplayIDs()
        DispatchQueue.main.async {
            self.detectorFailed = true
            for id in ids { self.plans[id] = .covered(DisplayDescriptor(id: id, bounds: CGDisplayBounds(id)), because: .detectorUnavailable) }
            self.present()
        }
    }

    // MARK: CaptureSink (capture queues)

    func capture(_ frame: CapturedFrame) {
        let id = frame.display.id
        let schedule: Bool = lock.withLock {
            guard accepting else { return false }
            mailboxes[id, default: FrameMailbox()].offer(frame)
            return scheduled.insert(id).inserted
        }
        if schedule { judgeQueue.async { [weak self] in self?.drain(id) } }
    }

    func captureFault(display id: UInt32, cause: FaultCause) {
        judgeQueue.async { [weak self] in
            guard let self else { return }
            let d = DisplayDescriptor(id: id, bounds: CGDisplayBounds(id))
            let plan = self.pipelines[id]?.cover(because: cause) ?? .covered(d, because: cause)
            DispatchQueue.main.async { self.plans[id] = plan; self.present() }
        }
    }

    func captureDisplays(_ displays: [DisplayDescriptor]) {
        judgeQueue.async { [weak self] in
            guard let self, let det = self.detector else { return }
            // The built-in (main) display first; displays beyond DISPLAYS_MAX are covered whole.
            let main = CGMainDisplayID()
            let sorted = displays.sorted { ($0.id == main ? 0 : 1, $0.id) < ($1.id == main ? 0 : 1, $1.id) }
            self.order = sorted.map(\.id)
            let judgedCount = min(sorted.count, Register.DISPLAYS_MAX)
            let share = Register.JUDGEMENT_BUDGET / Double(max(1, judgedCount))
            var fresh: [UInt32: DisplayPipeline] = [:]
            var out: [UInt32: CoverPlan] = [:]
            for (i, d) in sorted.enumerated() {
                let p = self.pipelines[d.id] ?? DisplayPipeline(display: d, judger: det, budgetShare: share, ignoredPIDs: [self.ownPID])
                p.setBudgetShare(share)
                fresh[d.id] = p
                out[d.id] = i < Register.DISPLAYS_MAX ? p.lastPlan : p.cover(because: .tooManyDisplays)
            }
            self.pipelines = fresh
            DispatchQueue.main.async { self.plans = out; self.present() }
        }
    }

    // MARK: Judging queue

    private func drain(_ id: UInt32) {
        while true {
            let next: CapturedFrame? = lock.withLock {
                let f = mailboxes[id]?.take()
                if f == nil { scheduled.remove(id) }
                return f
            }
            guard let f = next else { return }
            guard let p = pipelines[id], let idx = order.firstIndex(of: id), idx < Register.DISPLAYS_MAX else { continue }
            let start = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { self.busySince[id] = start }
            let plan = p.process(f, snapshot: WindowList.snapshot(), now: start)
            DispatchQueue.main.async {
                self.busySince[id] = nil
                guard self.running else { return }
                self.plans[id] = plan
                self.present()
            }
        }
    }

    // MARK: Main thread

    /// Judging that stalls on one frame covers that display whole until it catches up (step 3 of
    /// "slowness covers more"). The judging queue cannot do this itself while it is stuck.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.present() }
        }
    }

    @MainActor func present() {
        let now = ProcessInfo.processInfo.systemUptime
        var shown = plans
        for (id, t) in busySince where now - t > Register.JUDGING_STALL {
            if let d = shown[id]?.display { shown[id] = .covered(d, because: .judgingBehind) }
        }
        presenter.apply(Array(shown.values))
        // The repair card: whenever a display has been covered whole for two seconds or more.
        let causes = shown.values.compactMap(\.wholeDisplay)
        if causes.isEmpty { wholeSince = nil } else if wholeSince == nil { wholeSince = now }
        if let s = wholeSince, now - s >= 2, let actions = repairActions {
            repairCard.show(causes: causes.sorted { $0 == .notYetJudged ? false : $1 == .notYetJudged }, actions: actions)
        } else {
            repairCard.hide()
        }
        onChange?()
    }
}
