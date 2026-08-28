// Authoritative compute-device probe. Run: swift ane_probe.swift
//
// Do NOT use `ioreg | grep -i ane` for this — it finds nothing even on a
// bare-metal M2 Pro that demonstrably has a Neural Engine, so an empty result
// proves nothing. MLComputeDevice is the supported API (macOS 14+).
//
// Why it matters here: FluidAudio resolves `configuration?.computeUnits ?? .all`
// and the diarizer is pinned to .cpuAndNeuralEngine. On a host with no ANE the
// segmentation/embedding models silently fall back to CPU — a DIFFERENT
// execution path from the affected user's machine. GitHub-hosted Apple Silicon
// runners are VMs and may not expose the ANE.

import CoreML
import Foundation

if #available(macOS 14.0, *) {
    let devices = MLModel.availableComputeDevices
    print("MLModel.availableComputeDevices count = \(devices.count)")
    var hasANE = false, hasGPU = false, hasCPU = false
    for d in devices {
        switch d {
        case .cpu:          print("  - CPU");           hasCPU = true
        case .gpu:          print("  - GPU");           hasGPU = true
        case .neuralEngine: print("  - NEURAL ENGINE"); hasANE = true
        @unknown default:   print("  - unknown device")
        }
    }
    print("")
    print("cpu=\(hasCPU) gpu=\(hasGPU) ane=\(hasANE)")
    if !hasANE {
        print("WARNING: no Neural Engine on this host.")
        print("  .cpuAndNeuralEngine will fall back to CPU for segmentation/embedding.")
        print("  The fbank model is .cpuOnly regardless, so the FAULTING path is unaffected,")
        print("  but the overall execution mix differs from the affected user's machine.")
        print("  Report this alongside any result from this host.")
    }
} else {
    print("macOS < 14: MLModel.availableComputeDevices unavailable")
}
