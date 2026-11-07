// SPDX-License-Identifier: MIT

import AVFoundation

/// 一小段声音，带着每一刻有多响，好让东西跟着它动（“拾穗计划”页头像的彩蛋）。
/// 要用之前在后台解码一遍，掐掉前后的静音，量出每 10 毫秒的响度；播放用 AVAudioPlayer，
/// 它说得出放到了哪儿，跟着动的东西就对得上听到的声音。正在放时再 play() 什么也不做：
/// 连点不会叠出好几个声音，也不会一直从头开始（那样永远只听得到开头那一下）。
/// 不写日志，失败了也不写：彩蛋是让人发现的，不是让人在日志里读到的。只在主线程上使用。
final class SoundClip {
    /// 每秒量几次响度
    static let levelsPerSecond = 100

    /// 解码好的声音：去掉了前后静音的 WAV，和它每一段的响度
    struct Decoded {
        let wav: Data
        /// 每 `step` 帧一个，0 到 1
        let levels: [Float]
        let step: Int
        let sampleRate: Double
    }

    private let url: URL?
    private var decoded: Decoded?
    private var player: AVAudioPlayer?
    private var failed = false
    private var decoding = false
    /// 还在解码时就按了 play()
    private var playWhenReady = false
    /// 每次 release() 加一，丢掉之前还没解码完的结果
    private var generation = 0

    /// 自测时调成 0：照样放，只是听不见
    var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    init(url: URL?) {
        self.url = url
    }

    /// 读不了或解不开时为 false（比如文件没打包进去）
    var available: Bool { url != nil && !failed }
    var playing: Bool { player?.isPlaying == true }
    /// 放到第几秒（从掐掉静音后的开头算），没在放时为 nil
    var position: TimeInterval? { playing ? player?.currentTime : nil }

    /// 现在就在后台解码，这样第一次 play() 马上就响
    func prepare() {
        guard let url, player == nil, !decoding, !failed else { return }
        decoding = true
        let mine = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let clip = Self.decode(url)
            let player = clip.flatMap { try? AVAudioPlayer(data: $0.wav) }
            player?.prepareToPlay()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == mine else { return }
                self.decoding = false
                guard let clip, let player else {
                    self.failed = true
                    self.playWhenReady = false
                    return
                }
                player.volume = self.volume
                self.decoded = clip
                self.player = player
                if self.playWhenReady {
                    self.playWhenReady = false
                    self.start()
                }
            }
        }
    }

    /// 从头放；正在放时不管
    func play() {
        guard available, !playing else { return }
        guard player != nil else {
            playWhenReady = true
            prepare()
            return
        }
        start()
    }

    private func start() {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    /// 停下，解码好的声音也扔掉（离开这一页、窗口看不见时）。下次 prepare() 重新解码，只要几毫秒。
    func release() {
        generation += 1
        player?.stop()
        player = nil
        decoded = nil
        decoding = false
        playWhenReady = false
    }

    /// 放到的地方有多响：0 到 1，最响的那一刻是 1。没在放时为 0。
    func level() -> Double {
        guard let player, player.isPlaying, let decoded else { return 0 }
        return Self.level(in: decoded.levels, at: player.currentTime * decoded.sampleRate / Double(decoded.step))
    }

    // MARK: - 解码和响度

    /// 解成 16 位整数采样，掐掉前后的静音，量好响度，包成 WAV
    static func decode(_ url: URL) -> Decoded? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true) else { return nil }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate >= Double(levelsPerSecond),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else { return nil }
        var samples: [Int16] = []
        samples.reserveCapacity(Int(file.length) * channels)
        // MP3 的长度是估出来的，一直读到读不出东西为止
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            guard let data = buffer.int16ChannelData?[0] else { return nil }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength) * channels))
        }
        let step = Int(format.sampleRate) / levelsPerSecond
        guard let kept = audibleRange(loudness(samples, channels: channels, step: step)) else { return nil }
        let trimmed = Array(samples[kept.lowerBound * step * channels ..< min(samples.count, kept.upperBound * step * channels)])
        return Decoded(
            wav: wav(trimmed, channels: channels, sampleRate: Int(format.sampleRate)),
            levels: loudness(trimmed, channels: channels, step: step),
            step: step,
            sampleRate: format.sampleRate
        )
    }

    /// 每 step 帧的响度（各声道混在一起的均方根），按最响的那段缩放到 1；不到最响的 5% 算静音，为 0。
    static func loudness(_ samples: [Int16], channels: Int, step: Int) -> [Float] {
        let frames = samples.count / channels
        var levels: [Float] = []
        levels.reserveCapacity(frames / step + 1)
        var first = 0
        while first < frames {
            let end = min(frames, first + step)
            var sum = 0.0
            for frame in first ..< end {
                var mixed = 0.0
                for channel in 0 ..< channels { mixed += Double(samples[frame * channels + channel]) }
                mixed /= Double(channels) * 32768
                sum += mixed * mixed
            }
            levels.append(Float((sum / Double(end - first)).squareRoot()))
            first = end
        }
        let loudest = levels.max() ?? 0
        return levels.map { loudest > 0 && $0 / loudest >= 0.05 ? $0 / loudest : 0 }
    }

    /// 要留下的那几段：从第一段有声音的前面一段（留 10 毫秒）到最后一段有声音的。全是静音时为 nil。
    static func audibleRange(_ levels: [Float]) -> Range<Int>? {
        guard let first = levels.firstIndex(where: { $0 > 0 }), let last = levels.lastIndex(where: { $0 > 0 }) else { return nil }
        return max(0, first - 1) ..< last + 1
    }

    /// 第 at 段（可以带小数）的响度，两段之间按直线算
    static func level(in levels: [Float], at: Double) -> Double {
        guard at >= 0 else { return 0 }
        let i = Int(at)
        guard i + 1 < levels.count else { return i < levels.count ? Double(levels[i]) : 0 }
        let f = at - Double(i)
        return Double(levels[i]) * (1 - f) + Double(levels[i + 1]) * f
    }

    /// 16 位 PCM 包成 WAV，交给 AVAudioPlayer
    static func wav(_ samples: [Int16], channels: Int, sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func tag(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        tag("RIFF"); u32(36 + bytes); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate); u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        tag("data"); u32(bytes)
        // Apple 芯片和 Intel 都是小端，采样原样写进去
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
