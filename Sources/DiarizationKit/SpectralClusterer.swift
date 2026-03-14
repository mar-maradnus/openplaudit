/// Spectral clustering for speaker diarization.
///
/// Groups MFCC feature windows into speaker clusters using cosine similarity
/// and agglomerative hierarchical clustering.

import Accelerate
import Foundation

/// Cluster MFCC feature frames into speaker groups.
///
/// - Parameters:
///   - features: 2D array [numFrames][numCoeffs] of MFCC features
///   - maxSpeakers: Maximum number of speakers to detect (default 6)
///   - windowSize: Number of MFCC frames per embedding window (default 50 = 0.5s)
///   - windowStep: Step between windows (default 25 = 0.25s)
/// - Returns: Array of speaker labels (one per window), e.g. ["Speaker 1", "Speaker 2", ...]
func clusterSpeakers(
    features: [[Float]],
    maxSpeakers: Int = 6,
    windowSize: Int = 50,
    windowStep: Int = 25
) -> [String] {
    guard !features.isEmpty else { return [] }

    // Create windowed embeddings by averaging MFCC frames
    var embeddings = [[Float]]()
    var windowIdx = 0
    while windowIdx + windowSize <= features.count {
        let window = Array(features[windowIdx..<(windowIdx + windowSize)])
        let embedding = averageFrames(window)
        embeddings.append(embedding)
        windowIdx += windowStep
    }
    // Handle trailing frames
    if windowIdx < features.count && features.count - windowIdx >= windowSize / 2 {
        let window = Array(features[windowIdx...])
        embeddings.append(averageFrames(window))
    }

    guard !embeddings.isEmpty else { return [] }
    if embeddings.count == 1 { return ["Speaker 1"] }

    // Compute cosine similarity matrix
    let n = embeddings.count
    var simMatrix = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
    for i in 0..<n {
        for j in i..<n {
            let sim = cosineSimilarity(embeddings[i], embeddings[j])
            simMatrix[i][j] = sim
            simMatrix[j][i] = sim
        }
    }

    // Convert similarity to distance
    var distMatrix = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
    for i in 0..<n {
        for j in 0..<n {
            distMatrix[i][j] = 1.0 - simMatrix[i][j]
        }
    }

    // Agglomerative clustering — find optimal number of speakers
    let labels = agglomerativeClustering(distances: distMatrix, maxClusters: maxSpeakers)

    // Map cluster IDs to speaker names
    let uniqueClusters = Set(labels).sorted()
    let clusterToSpeaker = Dictionary(uniqueKeysWithValues: uniqueClusters.enumerated().map { ($1, "Speaker \($0 + 1)") })

    return labels.map { clusterToSpeaker[$0] ?? "Speaker 1" }
}

/// Map per-window speaker labels back to time ranges.
///
/// - Parameters:
///   - labels: Speaker label per window
///   - windowStep: MFCC frames per window step
///   - frameStep: Audio samples per MFCC frame step (default 160 = 10ms at 16kHz)
///   - sampleRate: Audio sample rate (default 16000)
/// - Returns: Merged speaker segments with start/end times
func labelsToSegments(
    labels: [String],
    windowStep: Int = 25,
    frameStep: Int = 160,
    sampleRate: Double = 16000
) -> [SpeakerSegment] {
    guard !labels.isEmpty else { return [] }

    let secondsPerWindow = Double(windowStep * frameStep) / sampleRate
    var segments = [SpeakerSegment]()
    var currentSpeaker = labels[0]
    var segStart: Double = 0

    for (i, label) in labels.enumerated().dropFirst() {
        if label != currentSpeaker {
            let segEnd = Double(i) * secondsPerWindow
            segments.append(SpeakerSegment(start: segStart, end: segEnd, speaker: currentSpeaker))
            currentSpeaker = label
            segStart = segEnd
        }
    }
    // Final segment
    let finalEnd = Double(labels.count) * secondsPerWindow
    segments.append(SpeakerSegment(start: segStart, end: finalEnd, speaker: currentSpeaker))

    return segments
}

// MARK: - Clustering internals

private func averageFrames(_ frames: [[Float]]) -> [Float] {
    guard let first = frames.first else { return [] }
    let dim = first.count
    var avg = [Float](repeating: 0, count: dim)
    for frame in frames {
        for d in 0..<dim {
            avg[d] += frame[d]
        }
    }
    let scale = 1.0 / Float(frames.count)
    for d in 0..<dim {
        avg[d] *= scale
    }
    return avg
}

func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, normA: Float = 0, normB: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
    vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))
    let denom = sqrt(normA) * sqrt(normB)
    return denom > 0 ? dot / denom : 0
}

private func agglomerativeClustering(distances: [[Float]], maxClusters: Int) -> [Int] {
    let n = distances.count
    guard n > 1 else { return [0] }

    // Start: each point is its own cluster
    var clusterAssignment = Array(0..<n)
    var activeClusterIDs = Set(0..<n)
    var nextClusterID = n

    // Merge history for finding optimal cut
    var mergeDistances = [Float]()

    // Track inter-cluster distances (average linkage)
    var clusterMembers = Dictionary(uniqueKeysWithValues: (0..<n).map { ($0, [$0]) })

    while activeClusterIDs.count > 1 {
        // Find closest pair
        var minDist: Float = .infinity
        var mergeA = -1, mergeB = -1

        let active = activeClusterIDs.sorted()
        for i in 0..<active.count {
            for j in (i + 1)..<active.count {
                let cA = active[i], cB = active[j]
                let dist = averageLinkageDistance(clusterMembers[cA]!, clusterMembers[cB]!, distances: distances)
                if dist < minDist {
                    minDist = dist
                    mergeA = cA
                    mergeB = cB
                }
            }
        }

        mergeDistances.append(minDist)

        // Merge clusters
        let newID = nextClusterID
        nextClusterID += 1
        let membersA = clusterMembers.removeValue(forKey: mergeA)!
        let membersB = clusterMembers.removeValue(forKey: mergeB)!
        clusterMembers[newID] = membersA + membersB
        activeClusterIDs.remove(mergeA)
        activeClusterIDs.remove(mergeB)
        activeClusterIDs.insert(newID)

        // Update assignments
        for idx in membersA + membersB {
            clusterAssignment[idx] = newID
        }
    }

    // Find optimal number of clusters using largest gap in merge distances
    let numClusters = findOptimalClusters(mergeDistances: mergeDistances, maxClusters: maxClusters, n: n)

    // Re-cut the dendrogram at the optimal level
    // Replay merges, stopping at numClusters
    var finalAssignment = Array(0..<n)
    var finalActiveIDs = Set(0..<n)
    var finalClusterMembers = Dictionary(uniqueKeysWithValues: (0..<n).map { ($0, [$0]) })
    var finalNextID = n

    // Replay merges up to n - numClusters
    var replayActiveIDs = Set(0..<n)

    // Re-do the clustering but stop early
    while replayActiveIDs.count > numClusters {
        var minDist: Float = .infinity
        var mergeA = -1, mergeB = -1

        let active = replayActiveIDs.sorted()
        for i in 0..<active.count {
            for j in (i + 1)..<active.count {
                let cA = active[i], cB = active[j]
                let dist = averageLinkageDistance(finalClusterMembers[cA]!, finalClusterMembers[cB]!, distances: distances)
                if dist < minDist {
                    minDist = dist
                    mergeA = cA
                    mergeB = cB
                }
            }
        }

        let newID = finalNextID
        finalNextID += 1
        let membersA = finalClusterMembers.removeValue(forKey: mergeA)!
        let membersB = finalClusterMembers.removeValue(forKey: mergeB)!
        finalClusterMembers[newID] = membersA + membersB
        replayActiveIDs.remove(mergeA)
        replayActiveIDs.remove(mergeB)
        replayActiveIDs.insert(newID)

        for idx in membersA + membersB {
            finalAssignment[idx] = newID
        }
    }

    // Normalize cluster IDs to 0-based sequential
    let uniqueIDs = Set(finalAssignment).sorted()
    let idMap = Dictionary(uniqueKeysWithValues: uniqueIDs.enumerated().map { ($1, $0) })
    return finalAssignment.map { idMap[$0]! }
}

private func averageLinkageDistance(_ a: [Int], _ b: [Int], distances: [[Float]]) -> Float {
    var sum: Float = 0
    for i in a {
        for j in b {
            sum += distances[i][j]
        }
    }
    return sum / Float(a.count * b.count)
}

private func findOptimalClusters(mergeDistances: [Float], maxClusters: Int, n: Int) -> Int {
    guard mergeDistances.count > 1 else { return 1 }

    // Find the largest gap in merge distances
    var maxGap: Float = 0
    var gapIdx = 0
    for i in 1..<mergeDistances.count {
        let gap = mergeDistances[i] - mergeDistances[i - 1]
        if gap > maxGap {
            maxGap = gap
            gapIdx = i
        }
    }

    // Number of clusters = n - gapIdx (merges before the gap)
    let numClusters = max(1, min(maxClusters, n - gapIdx))
    return numClusters
}
