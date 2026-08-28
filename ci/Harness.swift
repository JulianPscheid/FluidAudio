// BNNS offline-diarizer crash harness.
//
// Calls OfflineDiarizerManager.process(_ url:) with Hedy's *exact* production
// configuration (macos/Runner/FluidAudioHandler.swift), so the CPU/ANE code path
// where the EXC_BAD_ACCESS in libBNNS lives is actually exercised. The shipped
// `fluidaudiocli process` command cannot do this on v0.15.5: it has no
// --compute-units flag (that landed in 0.15.6), so it runs with .all and
// re-enables the GPU.
//
// usage: bnnsharness <audio.wav> [iteration-label]
//
// Set BNNS_ASR_WAV=<short.wav> to additionally run an ASR manager predicting
// CONCURRENTLY with the diarizer in the SAME process, for the whole diarization
// pass. This reproduces the load described in FluidInference/FluidAudio#661,
// whose trigger is cross-manager (ASR + diarizer on the shared e5rt queue),
// NOT intra-diarizer. Note up front: the patch under test only serializes work
// INSIDE OfflineDiarizerManager.process(), so if the crash appears only in this
// mode, the patch is NOT expected to fix it. That is a real result, not a
// misconfiguration.
// exit 0 = clean, 2 = usage error, 3 = thrown Swift error.
// A crash shows up as a signal (SIGSEGV/SIGBUS), not an exit code.

import CoreML
import Foundation
import FluidAudio

@available(macOS 14.0, *)
@main
struct Harness {

    /// Verbatim copy of Hedy's `FluidAudioHandler.offlineDiarizerConfig`.
    static let offlineDiarizerConfig = OfflineDiarizerConfig(
        segmentation: .init(
            windowDurationSeconds: 10.0,
            sampleRate: 16_000,
            minDurationOn: 0.0,
            minDurationOff: 0.0,
            stepRatio: 0.1,
            speechOnsetThreshold: 0.5,
            speechOffsetThreshold: 0.5
        ),
        embedding: .community,
        clustering: .init(
            threshold: 0.75,
            warmStartFa: 0.07,
            warmStartFb: 0.8
        ),
        vbx: .community,
        postProcessing: .community
    )

    /// Verbatim copy of Hedy's `FluidAudioHandler.diarizerModelConfiguration`.
    /// LOAD-BEARING: FluidAudio resolves `configuration?.computeUnits ?? .all`,
    /// so dropping this silently re-enables the GPU and the crash stops reproducing.
    nonisolated(unsafe) static let diarizerModelConfiguration: MLModelConfiguration = {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        return config
    }()

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }


    /// Continuously transcribe `wav` until cancelled, so ASR Core ML predictions
    /// overlap the entire diarization pass. Mirrors #661: ASR on DEFAULT compute
    /// units, diarizer pinned to .cpuAndNeuralEngine.
    static func startAsrLoad(wav: URL) async -> Task<Int, Never>? {
        do {
            let models = try await AsrModels.downloadAndLoad()
            let asr = AsrManager(models: models)
            log("ASR models loaded; starting concurrent ASR load from \(wav.lastPathComponent)")
            return Task.detached(priority: .userInitiated) {
                var passes = 0
                while !Task.isCancelled {
                    do {
                        let layers = await asr.decoderLayerCount
                        var state = TdtDecoderState.make(decoderLayers: layers)
                        _ = try await asr.transcribe(wav, decoderState: &state)
                        passes += 1
                    } catch {
                        if Task.isCancelled { break }
                        log("ASR pass error (continuing): \(error)")
                    }
                }
                return passes
            }
        } catch {
            log("ASR SETUP FAILED (continuing diarizer-only): \(error)")
            return nil
        }
    }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(
                Data("usage: bnnsharness <audio.wav> [iteration-label]\n".utf8))
            exit(2)
        }
        let audioURL = URL(fileURLWithPath: args[1])
        let label = args.count >= 3 ? args[2] : "-"

        log("harness start iteration=\(label) pid=\(getpid()) audio=\(audioURL.path)")
        log("computeUnits=cpuAndNeuralEngine stepRatio=0.1 embeddingBatchSize=\(offlineDiarizerConfig.embedding.batchSize)")

        let wall = Date()
        do {
            let manager = OfflineDiarizerManager(config: offlineDiarizerConfig)
            let prepStart = Date()
            try await manager.prepareModels(configuration: diarizerModelConfiguration)
            log(String(format: "models prepared in %.1fs", Date().timeIntervalSince(prepStart)))

            // #661 mode: cross-manager concurrency, same process.
            var asrTask: Task<Int, Never>? = nil
            if let asrPath = ProcessInfo.processInfo.environment["BNNS_ASR_WAV"], !asrPath.isEmpty {
                asrTask = await startAsrLoad(wav: URL(fileURLWithPath: asrPath))
                log("mode=ASR_CONCURRENT (cross-manager, per #661)")
            } else {
                log("mode=DIARIZER_ONLY")
            }

            let processStart = Date()

            // Cancellation probe: cancel process() mid-flight and measure how
            // long it takes to return. Bounds the live-session stall the
            // cancellation gate (91958612) can cause.
            if let cancelStr = ProcessInfo.processInfo.environment["BNNS_CANCEL_AFTER"],
               let cancelAfter = Double(cancelStr) {
                let box = UncheckedBox(manager)
                let url = audioURL
                let task = Task.detached(priority: .userInitiated) { () -> Int in
                    let r = try await box.value.process(url)
                    return r.segments.count
                }
                try? await Task.sleep(nanoseconds: UInt64(cancelAfter * 1_000_000_000))
                let cancelAt = Date()
                log("CANCEL ISSUED at +\(cancelAfter)s into process()")
                task.cancel()
                do {
                    let n = try await task.value
                    let dt = Date().timeIntervalSince(cancelAt)
                    log(String(format: "CANCEL RETURNED normally (segments=%d) %.3fs after cancel", n, dt))
                } catch {
                    let dt = Date().timeIntervalSince(cancelAt)
                    log(String(format: "CANCEL RETURNED via %@ %.3fs after cancel",
                               String(describing: type(of: error)), dt))
                }
                log(String(format: "cancel-probe total=%.1fs", Date().timeIntervalSince(wall)))
                exit(0)
            }
            let lastLogged = LastLogged()
            let result = try await manager.process(audioURL) { done, total in
                // Progress heartbeat so a crash log shows how far the run got.
                if done == total || done % 200 == 0 {
                    lastLogged.note(done: done, total: total)
                }
            }
            let processSeconds = Date().timeIntervalSince(processStart)
            if let asrTask {
                asrTask.cancel()
                let passes = await asrTask.value
                log("ASR concurrent load stopped after \(passes) completed passes")
            }
            let speakers = Set(result.segments.map { $0.speakerId }).count
            log(
                String(
                    format:
                        "OK iteration=%@ segments=%d speakers=%d process=%.1fs total=%.1fs",
                    label, result.segments.count, speakers, processSeconds,
                    Date().timeIntervalSince(wall)))
            exit(0)
        } catch {
            log("ERROR iteration=\(label) \(error)")
            exit(3)
        }
    }
}

/// Escape hatch so the non-Sendable manager can be handed to a detached Task
/// purely so the harness can cancel it. Test-harness only.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Tiny thread-safe progress printer (the callback is @Sendable).
final class LastLogged: @unchecked Sendable {
    private let lock = NSLock()
    func note(done: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] segmentation chunk \(done)/\(total)")
        fflush(stdout)
    }
}
