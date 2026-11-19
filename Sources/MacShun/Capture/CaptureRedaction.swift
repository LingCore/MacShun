// SPDX-License-Identifier: MIT

import Vision

enum CaptureRedaction {
    static let queue = DispatchQueue(label: "MacShun.CaptureRedaction", qos: .userInitiated)

    private static let contacts: NSRegularExpression = {
        let mailbox = #"(?<![a-z0-9._%+@-])[a-z0-9_%+-]+(?:\.[a-z0-9_%+-]+)*[\p{Zs}]?@[\p{Zs}]?"#
        let label = #"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"#
        // 快速识别偶尔会在域名的点后插入空格。先匹配连续域名，以免把下一句也框进去。
        let domain = #"(?:(?:\#(label)\.)+[a-z]{2,}|(?:\#(label)\.[\p{Zs}]?)+[a-z]{2,})(?![a-z0-9@-])"#
        let mobile = #"(?<![a-z0-9+@])(?:\+86[\p{Zs}-]*)?1[3-9][0-9][\p{Zs}-]?[0-9]{4}[\p{Zs}-]?[0-9]{4}(?![a-z0-9@])"#
        return try! NSRegularExpression(pattern: "\(mailbox)\(domain)|\(mobile)", options: [.caseInsensitive])
    }()

    static func contactRanges(in line: String) -> [Range<String.Index>] {
        contacts.matches(in: line, range: NSRange(line.startIndex..., in: line))
            .compactMap { Range($0.range, in: line) }
    }

    /// 返回图片坐标（左下为原点），向外留出余量并对齐实际像素。
    static func recognize(in image: CGImage) throws -> [CGRect] {
        try autoreleasepool {
            let request = VNRecognizeTextRequest()
            // 目标都是 ASCII。快速识别能定位字符，并避免首次编译识别模型拖慢操作。
            request.recognitionLevel = .fast
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            return (request.results ?? []).flatMap { observation -> [CGRect] in
                guard let text = observation.topCandidates(1).first else { return [] }
                return contactRanges(in: text.string).compactMap { range in
                    let normalized = (try? text.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                    let box = VNImageRectForNormalizedRect(normalized, image.width, image.height)
                    let margin = max(2, box.height * 0.16)
                    let padded = box.insetBy(dx: -margin, dy: -margin).integral.intersection(bounds)
                    return padded.isEmpty ? nil : padded
                }
            }
        }
    }
}
