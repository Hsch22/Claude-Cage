import Foundation
import CoreGraphics

@main
struct MacCanvasLayoutSettlementTest {
    static func check(_ value: Bool) { precondition(value) }
    @MainActor
    static func main() async throws {
        let wanted32 = CGSize(width: 1240, height: 872)
        let wanted38 = CGSize(width: 1240, height: 878)
        let at872 = CGRect(origin: .zero, size: wanted32)
        let at878 = CGRect(origin: .zero, size: wanted38)
        var initial = MacCanvasLayoutSettlement(requested: wanted32)
        // The observed first layout was crop 38 on an outer height of 872:
        // publishing that sample would expose 834 content points, not 840.
        check(try initial.observe(bounds: at872, crop: 38, wanted: wanted38) == .resize(wanted38))
        check(try initial.observe(bounds: at878, crop: 38, wanted: wanted38) == .wait)
        check(try initial.observe(bounds: at878, crop: 32, wanted: wanted32) == .resize(wanted32))
        check(try initial.observe(bounds: at872, crop: 32, wanted: wanted32) == .wait)
        check(try initial.observe(bounds: at872, crop: 32, wanted: wanted32) == .settled)
        precondition(at872.height - 32 == 840)

        var changing = MacCanvasLayoutSettlement(requested: wanted32)
        for n in 0..<12 {
            let crop: CGFloat = n % 2 == 0 ? 38 : 32
            let wanted = crop == 38 ? wanted38 : wanted32
            let decision = try changing.observe(bounds: CGRect(origin: .zero, size: wanted), crop: crop, wanted: wanted)
            precondition(decision != .settled)
        }
        do {
            _ = try changing.observe(bounds: at872, crop: 32, wanted: wanted32)
            fatalError("An unstable title bar must fail after the bounded observation budget")
        } catch MacCanvasLayoutSettlement.Problem.unstable {}

        var moving = MacCanvasLayoutSettlement(requested: wanted32)
        check(try moving.observe(bounds: at872, crop: 32, wanted: wanted32) == .wait)
        let moved = at872.offsetBy(dx: 10, dy: 0)
        check(try moving.observe(bounds: moved, crop: 32, wanted: wanted32) == .wait)
        check(try moving.observe(bounds: moved, crop: 32, wanted: wanted32) == .settled)
        print("Layout crop correction, bounded instability, and origin settling passed")
        var transactions = MacCanvasLayoutTransactions()
        let oldLayout = transactions.begin()
        precondition(transactions.isCurrent(oldLayout))
        // A second viewport wins while the first resize is suspended.
        let newLayout = transactions.begin()
        precondition(!transactions.isCurrent(oldLayout))
        precondition(transactions.isCurrent(newLayout))
        precondition(!transactions.invalidate(oldLayout), "Old failure must not invalidate new layout")
        var probes = 0
        do {
            try transactions.validateCrop(oldLayout) { probes += 1; return true }
            fatalError("An old capture completion must not validate the newer layout")
        } catch MacCanvasLayoutTransactions.Problem.stale {}
        precondition(probes == 0)
        // A background frame does not establish successful crop validation.
        try transactions.validateCrop(newLayout) { probes += 1; return nil }
        precondition(probes == 1)
        try transactions.validateCrop(newLayout) { probes += 1; return true }
        precondition(probes == 2)
        for _ in 0..<100 {
            try transactions.validateCrop(newLayout) { probes += 1; return false }
        }
        precondition(probes == 2, "Warm cached frames must perform no additional AX crop probe")
        let thirdLayout = transactions.begin()
        do {
            try transactions.validateCrop(thirdLayout) { probes += 1; return false }
            fatalError("An incorrect fresh crop must not be accepted")
        } catch MacCanvasLayoutTransactions.Problem.cropChanged {}
        precondition(transactions.invalidate(thirdLayout))
        precondition(!transactions.isCurrent(thirdLayout))
        precondition(!transactions.invalidate(oldLayout))
        print("Transaction interleaving, stale completion, background validation, and zero-probe warm frames passed")
        var attempts = 0
        var frameTransactions = MacCanvasLayoutTransactions()
        let published: (crop: CGFloat, content: CGFloat) = try await MacCanvasFrameConvergence.run { recovery in
            attempts += 1
            if let recovery { precondition(frameTransactions.isCurrent(recovery.recoveryGeneration)) }
            let generation = frameTransactions.begin()
            let sampledCrop: CGFloat = attempts == 1 ? 38 : 32
            // The actual title bar changes after capture on the first attempt.
            do {
                try frameTransactions.validateCrop(generation) { sampledCrop == 32 }
            } catch MacCanvasLayoutTransactions.Problem.cropChanged {
                precondition(frameTransactions.invalidate(generation))
                throw MacCanvasCropChanged(recoveryGeneration: frameTransactions.current)
            }
            return (sampledCrop, CGFloat(872) - sampledCrop)
        }
        precondition(attempts == 2 && published.crop == 32 && published.content == 840)
        attempts = 0
        do {
            let _: Int = try await MacCanvasFrameConvergence.run { _ in
                attempts += 1
                throw MacCanvasCropChanged(recoveryGeneration: UUID())
            }
            fatalError("Repeated capture crop changes must fail")
        } catch MacCanvasFrameConvergence.Problem.unstable {}
        precondition(attempts == 3)
        enum TargetFailure: Error { case changed }
        attempts = 0
        do {
            let _: Int = try await MacCanvasFrameConvergence.run { recovery in
                attempts += 1
                if recovery != nil { throw TargetFailure.changed }
                throw MacCanvasCropChanged(recoveryGeneration: UUID())
            }
            fatalError("A changed window during recovery must not be retried")
        } catch TargetFailure.changed {}
        precondition(attempts == 2)
        attempts = 0
        do {
            let _: Int = try await MacCanvasFrameConvergence.run { _ in
                attempts += 1
                throw MacCanvasLayoutTransactions.Problem.stale
            }
            fatalError("Stale generations must never enter crop recovery")
        } catch MacCanvasLayoutTransactions.Problem.stale {}
        precondition(attempts == 1)
        print("Capture crop convergence, bounded failure, target replacement and stale-generation rejection passed")


    }
}
