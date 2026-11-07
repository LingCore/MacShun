// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MacShun

@Suite("头像的声音")
struct SoundClipTests {
    @Test func loudnessScalesToLoudestAndMutesNearSilence() {
        // 单声道，每段 2 帧：静音、最响、一半、最响的 4%
        let samples: [Int16] = [0, 0, 16384, -16384, 8192, -8192, 655, -655]
        let levels = SoundClip.loudness(samples, channels: 1, step: 2)
        #expect(levels.count == 4)
        #expect(levels[0] == 0)
        #expect(levels[1] == 1)
        #expect(abs(levels[2] - 0.5) < 0.001)
        #expect(levels[3] == 0)
    }

    @Test func loudnessMixesChannels() {
        // 立体声两个声道反相，混在一起就没声音了
        let levels = SoundClip.loudness([1000, -1000, 1000, -1000, 4000, 4000], channels: 2, step: 1)
        #expect(levels == [0, 0, 1])
    }

    @Test func keepsOneStepBeforeTheSound() {
        #expect(SoundClip.audibleRange([0, 0, 0.5, 1, 0, 0.2, 0, 0]) == 1 ..< 6)
        #expect(SoundClip.audibleRange([0.3, 0, 0]) == 0 ..< 1)
        #expect(SoundClip.audibleRange([0, 0]) == nil)
    }

    @Test func levelInterpolatesBetweenSteps() {
        let levels: [Float] = [0, 1, 0.5]
        #expect(SoundClip.level(in: levels, at: 0.5) == 0.5)
        #expect(SoundClip.level(in: levels, at: 1.5) == 0.75)
        #expect(SoundClip.level(in: levels, at: 2.2) == 0.5)
        #expect(SoundClip.level(in: levels, at: 3) == 0)
        #expect(SoundClip.level(in: levels, at: -1) == 0)
    }

    @Test func wavHeader() {
        let wav = SoundClip.wav([1, -1, 2, -2], channels: 2, sampleRate: 44100)
        #expect(wav.count == 44 + 8)
        #expect(String(decoding: wav[0 ..< 4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[36 ..< 40], as: UTF8.self) == "data")
        let u32 = { (at: Int) in wav[at ..< at + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        #expect(u32(4) == 36 + 8)
        #expect(u32(24) == 44100)
        #expect(u32(28) == 44100 * 4)
        #expect(u32(40) == 8)
    }

    /// 打包进程序的那段声音能解开，前后的静音掐掉了，最响的地方是 1
    @Test func decodesTheBundledSound() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let clip = try #require(SoundClip.decode(root.appendingPathComponent("Resources/ikun.mp3")))
        let seconds = Double(clip.levels.count) / Double(SoundClip.levelsPerSecond)
        #expect(seconds > 1 && seconds < 3.5)
        #expect(clip.levels.max() == 1)
        #expect(clip.levels.first == 0)   // 前面留的那一段
        #expect(clip.levels[1] > 0)
        #expect(clip.levels.last! > 0)
        // 立体声 16 位：每段 step 帧、每帧 4 字节，最后一段可能不满
        let bytes = clip.wav.count - 44
        #expect(bytes > (clip.levels.count - 1) * clip.step * 4 && bytes <= clip.levels.count * clip.step * 4)
    }
}
