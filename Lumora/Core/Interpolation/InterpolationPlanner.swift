import Foundation

struct InterpolationSettings: Codable, Hashable {
    enum Mode: Codable, Hashable {
        case off
        case multiply(Int)                     // 2x, 3x, 4x, 8x the source frame rate
        case targetFPS(num: Int, den: Int)     // e.g. 23.976 -> exactly 60 or 59.94
        case slowMotion(factor: Int)           // generate factor x frames, play at the source rate
    }
    var mode: Mode = .off
    var primaryModelID: String = "rife-4"
    var repairModelID: String? = "film"
    var artifactRepair = true
    var sensitivity: Float = 0.5               // 0 = only obvious artifacts, 1 = very strict
    var smoothDuplicates = true                // interpolate across repeated frames (animation on twos, VFR padding)
    var intelligence: MotionIntelligence = .eachFrame
    var confidence: Double = 0.97              // per-scene routing keeps testing until this sure
    var grainAware = false                     // de-grain → interpolate → re-grain, and grain-blind artifact checks
    var flickerCheck = true                    // consecutive generated frames must move evenly
    var routes: [Int: SceneRoute] = [:]        // scene → chosen model (from the motion map)
}

enum MotionIntelligence: String, Codable, CaseIterable, Identifiable {
    case eachFrame = "Check each frame"
    case perScene = "Route a model per scene"
    case exhaustive = "Exhaustive until confident"
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .eachFrame: return "One model for the film; every generated frame is checked and repaired on its own. Fastest."
        case .perScene: return "Tests the likely models on real frames from each kind of motion and routes each scene to its winner."
        case .exhaustive: return "Tests every installed model on every scene until it is statistically confident the winner is best, then double-generates risky scenes and keeps the cleaner frame. Very slow, maximum quality."
        }
    }
}

/// The verdict for one scene in the motion map.
struct SceneRoute: Codable, Hashable {
    enum Status: String, Codable { case confident = "Confident", tied = "Models tied", uncertain = "Not yet confident", skipped = "Static or too short" }
    var scene: Int
    var model: String
    var runnerUp: String?
    var confidence: Double          // probability the chosen model beats every alternative on this scene
    var status: Status
    var trials: Int
    var motion: Double              // average change between frames (0…1)
    var pain: Double                // expected share of generated frames that need repair
    var advantage: Double           // SSIM gain over the runner-up
}

struct PlannedFrame: Hashable {
    enum Kind: Hashable { case original, generated, holdAcrossCut, transitionBlend }
    var a: Int
    var b: Int
    var t: Float
    var kind: Kind
}

/// Decides, for every output frame, which source frames it comes from and how it is made.
/// Never interpolates across a cut (that's where the classic "morphing" artifacts come from),
/// and blends through fades and dissolves, where optical flow has nothing real to track.
enum InterpolationPlanner {
    static func plan(sourceFrames n: Int, sourceRate: (num: Int, den: Int), settings: InterpolationSettings,
                     analysis: AnalysisResult?) -> (frames: [PlannedFrame], rate: (num: Int, den: Int)) {
        let srcFps = Double(sourceRate.num) / Double(sourceRate.den)
        let genRate: (Int, Int)
        let outRate: (Int, Int)
        switch settings.mode {
        case .off:
            return ((0..<n).map { PlannedFrame(a: $0, b: $0, t: 0, kind: .original) }, sourceRate)
        case .multiply(let k):
            genRate = (sourceRate.num * k, sourceRate.den); outRate = genRate
        case .targetFPS(let num, let den):
            genRate = (num, den); outRate = genRate
        case .slowMotion(let k):
            genRate = (sourceRate.num * k, sourceRate.den); outRate = sourceRate
        }
        let genFps = Double(genRate.0) / Double(genRate.1)
        let count = Int((Double(n - 1) * genFps / srcFps).rounded(.down)) + 1
        // Unique frames: repeated frames are skipped so motion is interpolated between real drawings.
        let dupes = settings.smoothDuplicates ? (analysis?.duplicateFrames ?? []) : []
        let keys = (0..<n).filter { !dupes.contains($0) || (analysis?.cutFrames.contains($0) ?? false) }
        var frames: [PlannedFrame] = []
        frames.reserveCapacity(count)
        var ki = 0
        for k in 0..<count {
            let pos = Double(k) * srcFps / genFps
            while ki + 1 < keys.count, Double(keys[ki + 1]) <= pos { ki += 1 }
            let a = keys[ki]
            guard ki + 1 < keys.count else {
                frames.append(PlannedFrame(a: a, b: a, t: 0, kind: .original))
                continue
            }
            let b = keys[ki + 1]
            let t = Float((pos - Double(a)) / Double(b - a))
            if t < 1e-4 {
                frames.append(PlannedFrame(a: a, b: a, t: 0, kind: .original))
                continue
            }
            if let cuts = analysis?.cutFrames, ((a + 1)...b).contains(where: { cuts.contains($0) }) {
                let nearest = t < 0.5 ? a : b
                frames.append(PlannedFrame(a: nearest, b: nearest, t: 0, kind: .holdAcrossCut))
            } else if analysis?.transition(containing: a) != nil || analysis?.transition(containing: b) != nil {
                frames.append(PlannedFrame(a: a, b: b, t: t, kind: .transitionBlend))
            } else {
                frames.append(PlannedFrame(a: a, b: b, t: t, kind: .generated))
            }
        }
        return (frames, outRate)
    }
}
