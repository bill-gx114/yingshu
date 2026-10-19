import AppKit
import AVFoundation
import QuartzCore

/// A silent original clay traveler. All poses are genuine 3D renders made at build
/// time; choosing a timestamp is deterministic in preview, PNG, and MP4 exports.
@MainActor enum CompanionStickerRenderer {
    static let poseCount = 25
    static let turnDuration = 1.2
    private static let poses: [CGImage] = {
        let roots = [Bundle.main.resourceURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")].compactMap { $0 }
        return (0..<poseCount).compactMap { index in
            let name = String(format: "companion-%02d.png", index)
            for root in roots {
                if let image = NSImage(contentsOf: root.appendingPathComponent(name)),
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
            }
            return nil
        }
    }()
    private static let bubbles: NSCache<NSString, Bubble> = {
        let cache = NSCache<NSString, Bubble>(); cache.totalCostLimit = 32 * 1024 * 1024; return cache
    }()

    static func poseIndex(elapsed: Double?) -> Int {
        guard let elapsed, elapsed.isFinite else { return 0 }
        return max(0, min(poseCount - 1, Int(floor(max(0, elapsed) / turnDuration * Double(poseCount - 1)))))
    }

    static func layer(for caption: Caption, canvas: CGSize, localTime: Double?) -> CALayer {
        let base = min(canvas.width, canvas.height) / 1080
        let characterHeight = canvas.height * 0.125
        let characterWidth = characterHeight * 0.8
        let gap = 4 * base
        let maxBubbleWidth = min(canvas.width * 0.64, canvas.width * 0.85 - characterWidth - gap)
        let key = "\(canvas.width)x\(canvas.height)|\(caption.text)" as NSString
        let bubble: Bubble
        if let cached = bubbles.object(forKey: key) { bubble = cached }
        else {
            bubble = bubbleRaster(text: caption.text, maximumWidth: maxBubbleWidth, canvas: canvas, base: base)
            if let image = bubble.image { bubbles.setObject(bubble, forKey: key, cost: image.bytesPerRow * image.height) }
        }
        let tailY = characterHeight * 0.45
        let height = max(characterHeight, tailY + bubble.size.height)
        let width = characterWidth + gap + bubble.size.width
        let root = CALayer(); root.frame = CGRect(x: canvas.width * 0.075, y: canvas.height * 0.12, width: width, height: height)
        root.name = bubble.compact ? "caption-compact" : "caption-companion"
        // A small contact shadow anchors the traveler without a large opaque sticker.
        let shadow = CALayer(); shadow.frame = CGRect(x: characterWidth * 0.25, y: characterHeight * 0.025,
                                                      width: characterWidth * 0.52, height: characterHeight * 0.035)
        shadow.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        shadow.cornerRadius = shadow.bounds.height / 2; root.addSublayer(shadow)
        let character = CALayer(); character.name = "companion-character"
        character.frame = CGRect(x: 0, y: 0, width: characterWidth, height: characterHeight)
        character.contentsGravity = .resizeAspect
        let index = poseIndex(elapsed: localTime.map { $0 - caption.start })
        if poses.indices.contains(index) { character.contents = poses[index] }
        root.addSublayer(character)
        let card = CALayer(); card.name = "companion-bubble"
        card.frame = CGRect(x: characterWidth + gap, y: tailY, width: bubble.size.width, height: bubble.size.height)
        card.contents = bubble.image; card.contentsGravity = .resize
        card.shadowColor = NSColor.black.cgColor; card.shadowOpacity = 0.12
        card.shadowRadius = 7 * base; card.shadowOffset = CGSize(width: 0, height: -3 * base)
        if let localTime {
            let progress = min(1, max(0, (localTime - caption.start) / 0.22))
            let scale = 0.94 + 0.06 * (1 - pow(1 - progress, 3))
            card.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        root.addSublayer(card)
        return root
    }

    /// Absolute output times preserve one gesture even when overlap changes split
    /// a caption into several Core Animation layers.
    static func animate(_ layer: CALayer, captionStart: Double, totalDuration: Double) {
        guard totalDuration > 0 else { return }
        if let character = layer.sublayers?.first(where: { $0.name == "companion-character" }), poses.count == poseCount {
            var times: [NSNumber] = [0]
            var images: [Any] = [poses[0]]
            for index in 0..<poseCount {
                let t = max(0, captionStart + Double(index) / Double(poseCount - 1) * turnDuration)
                guard t < totalDuration else { break }
                let fraction = t / totalDuration
                if fraction == times.last!.doubleValue { images[images.count - 1] = poses[index] }
                else { times.append(NSNumber(value: fraction)); images.append(poses[index]) }
            }
            if times.last!.doubleValue < 1 { times.append(1); images.append(images.last!) }
            let animation = CAKeyframeAnimation(keyPath: "contents"); animation.values = images; animation.keyTimes = times
            animation.calculationMode = .discrete; configure(animation, duration: totalDuration)
            character.add(animation, forKey: "companion-turn")
        }
        if let card = layer.sublayers?.first(where: { $0.name == "companion-bubble" }) {
            let start = max(0, min(1, captionStart / totalDuration))
            let end = min(1, (captionStart + 0.22) / totalDuration)
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = [0.94, 0.94, 1, 1]; animation.keyTimes = [0, NSNumber(value: start), NSNumber(value: end), 1]
            animation.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
            configure(animation, duration: totalDuration); card.add(animation, forKey: "companion-bubble-arrival")
        }
    }

    private static func configure(_ animation: CAAnimation, duration: Double) {
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = duration; animation.isRemovedOnCompletion = false; animation.fillMode = .both
    }

    private static func bubbleRaster(text raw: String, maximumWidth: CGFloat, canvas: CGSize, base: CGFloat) -> Bubble {
        let initial = 42 * base, inset = 25 * base, tail = 16 * base
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.alignment = .left
        let display = raw.utf16.count > 4000 ? String(raw.prefix(4000)) + "\n文字过长，请拆成几句。" : raw
        var fontSize = initial, measured = CGRect.zero, text = NSAttributedString()
        repeat {
            paragraph.lineSpacing = fontSize * 0.22
            text = NSAttributedString(string: display, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.19, green: 0.25, blue: 0.23, alpha: 1), .paragraphStyle: paragraph])
            measured = text.boundingRect(with: CGSize(width: max(1, maximumWidth - inset * 2 - tail), height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            if measured.height + inset * 2 <= canvas.height * 0.57 || fontSize <= base { break }
            fontSize *= 0.9
        } while true
        let size = CGSize(width: ceil(min(maximumWidth, max(fontSize * 3, measured.width + inset * 2 + tail))),
                          height: ceil(measured.height + inset * 2))
        let image = NSImage(size: size); image.lockFocus()
        let body = CGRect(x: tail, y: 0, width: size.width - tail, height: size.height)
        let path = NSBezierPath(roundedRect: body, xRadius: 23 * base, yRadius: 23 * base)
        let pointer = NSBezierPath(); pointer.move(to: CGPoint(x: tail + 2 * base, y: 20 * base))
        pointer.line(to: CGPoint(x: 0, y: 14 * base)); pointer.line(to: CGPoint(x: tail + 2 * base, y: 41 * base)); pointer.close()
        NSColor(srgbRed: 1, green: 0.985, blue: 0.94, alpha: 0.98).setFill(); path.fill(); pointer.fill()
        NSColor(srgbRed: 0.89, green: 0.68, blue: 0.54, alpha: 0.65).setStroke(); path.lineWidth = 1.5 * base; path.stroke()
        text.draw(with: CGRect(x: tail + inset, y: inset, width: size.width - tail - inset * 2, height: size.height - inset * 2),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        image.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        return Bubble(image: image.cgImage(forProposedRect: &rect, context: nil, hints: nil), size: size, compact: fontSize < initial * 0.6)
    }

    private final class Bubble {
        let image: CGImage?; let size: CGSize; let compact: Bool
        init(image: CGImage?, size: CGSize, compact: Bool) { self.image = image; self.size = size; self.compact = compact }
    }
}
