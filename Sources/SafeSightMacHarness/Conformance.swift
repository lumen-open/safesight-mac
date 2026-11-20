// SPDX-License-Identifier: Apache-2.0
// The harness's part of the conformance kit (tools/conformance/run.sh, spec/detector-contract.md).
//
//   bundlecheck --models DIR   loads DIR exactly as the app does: the sealed hash list, the sealed manifest, every
//                              model's shape, the sealed cut-off table. Prints what it holds; exits 1 if refused.
//   parity --bundle DIR        (lab build only) each model against its reference outputs (conformance/<id>/
//                              reference.json) on every compute unit the reference lists; the declared units must pass,
//                              and every broken control must fail: the kit's own (red and blue swapped) and any shipped
//                              as conformance/<id>/broken/*.mlpackage. Prints JSON; exits 1 on any failure.
import DetectorCore
import Foundation
import Preprocess
import SafeSightMacWatcher

enum Conformance {
    /// The models a sealed folder names, for reports: ids and slots, no scores.
    static func describe(folder: URL) -> String {
        guard let m = try? WatcherModels.readManifest(folder: folder) else { return "the bundle's manifest could not be read" }
        let models = m.models.map { "\($0.id) (\($0.slot == .tieBreaker ? "tie-breaker" : "family " + $0.slot.rawValue))" }
        return models.joined(separator: ", ") + (m.families == 1 ? "; single-family mode" : "")
    }

    static func bundleCheck(folder: URL, rule: DetectorRule) -> Never {
        do {
            _ = try WatcherModels.loadDetector(folder: folder, rule: rule)
            print("bundle loads: \(describe(folder: folder)); sealed list, manifest, shapes and cut-off table checked")
            exit(0)
        } catch {
            print("FAIL: the bundle was refused (every display would be covered whole): \(error)")
            exit(1)
        }
    }

    #if SAFESIGHTMAC_LAB
    /// A difference for JSON, which has no infinity (a model that gave an unusable score).
    static func number(_ f: Float) -> Any { f.isFinite ? Double(f) : "not a usable score" }

    static func parity(bundle: URL, json: String?) -> Never {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent(ModelManifest.fileName)),
              let manifest = try? ModelManifest.decode(data) else { fail("parity: no readable \(ModelManifest.fileName) in \(bundle.path)") }
        var ok = true
        var out: [[String: Any]] = []
        for model in manifest.models {
            let dir = bundle.appendingPathComponent("conformance/\(model.id)")
            guard let rd = try? Data(contentsOf: dir.appendingPathComponent("reference.json")),
                  let ref = try? JSONSerialization.jsonObject(with: rd) as? [String: Any],
                  let tol = ref["tolerance"] as? [String: Double], let inputs = ref["inputs"] as? [[String: Any]] else {
                print("FAIL: \(model.id): no readable reference.json"); ok = false; continue
            }
            var tensors: [[UInt8]] = [], reference: [Float] = []
            for x in inputs {
                guard let f = x["file"] as? String, let s = x["flagScore"] as? Double,
                      let img = ImageLoading.load(dir.appendingPathComponent(f)),
                      let t = try? Preprocessor.run(img, rect: PixelRect(x: 0, y: 0, w: img.width, h: img.height), side: model.inputSide, jitterSeed: nil)
                else { fail("parity: \(model.id): unreadable input \(x["file"] ?? "?")") }
                tensors.append(t); reference.append(Float(s))
            }
            let declared = model.computeUnits
            guard let tDeclared = tol[declared.rawValue] else { print("FAIL: \(model.id): no tolerance for \(declared.rawValue)"); ok = false; continue }
            var record: [String: Any] = ["model": model.id, "inputs": inputs.count, "declaredUnits": declared.rawValue]
            var units: [[String: Any]] = []
            for (name, t) in tol.sorted(by: { $0.key < $1.key }) {
                guard let u = ModelManifest.Units(rawValue: name) else { print("FAIL: \(model.id): unknown units \(name)"); ok = false; continue }
                let required = u == declared
                do {
                    let r = try LabParity.run(model, url: bundle.appendingPathComponent(model.package), units: u, tensors: tensors,
                                              reference: reference, tolerance: Float(t))
                    units.append(["units": name, "tolerance": t, "maxDiff": number(r.maxDiff), "within": r.within, "pass": r.pass, "required": required])
                    if required && !r.pass { ok = false; print("FAIL: \(model.id) on \(name): \(r.count - r.within) of \(r.count) inputs beyond \(t)") }
                } catch {
                    units.append(["units": name, "error": "\(error)", "pass": false, "required": required])
                    if required { ok = false; print("FAIL: \(model.id) on \(name): \(error)") }
                }
            }
            record["parity"] = units
            // The broken controls: each must fail on the declared units.
            var controls: [[String: Any]] = []
            func control(_ name: String, _ url: URL, swap: Bool) {
                let r = try? LabParity.run(model, url: url, units: declared, tensors: tensors, reference: reference, tolerance: Float(tDeclared), swapRedBlue: swap)
                let failed = r.map { !$0.pass } ?? true
                controls.append(["control": name, "failed": failed, "maxDiff": r.map { number($0.maxDiff) } ?? NSNull()])
                if !failed { ok = false; print("FAIL: \(model.id): the broken control \(name) passed parity, so the check cannot tell") }
            }
            control("red and blue swapped (the kit's own)", bundle.appendingPathComponent(model.package), swap: true)
            let broken = dir.appendingPathComponent("broken")
            for f in ((try? FileManager.default.contentsOfDirectory(atPath: broken.path)) ?? []).sorted() where f.hasSuffix(".mlpackage") {
                control(f, broken.appendingPathComponent(f), swap: false)
            }
            record["controls"] = controls
            out.append(record)
        }
        let doc: [String: Any] = ["run": "safesightmac-parity/1", "pass": ok, "models": out,
                                  "method": "Each reference input judged whole (kestrel-preprocess/1, no jitter); the largest flag-score difference against the reference outputs shipped with the model. The declared compute units must be within tolerance on every input; every broken control must not be."]
        let bytes = (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        if let j = json { try? bytes.write(to: URL(fileURLWithPath: j)) }
        print(String(decoding: bytes, as: UTF8.self))
        print(ok ? "parity: every model within tolerance on its declared compute units, and every broken control failed" : "parity: FAILED")
        exit(ok ? 0 : 1)
    }
    #endif
}
