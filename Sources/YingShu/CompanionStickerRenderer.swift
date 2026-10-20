import AppKit
import AVFoundation
import QuartzCore
import SceneKit

/// The classic traveler keeps its original PNGs. Personal travelers use the same
/// rounded 3D construction, camera and deterministic gesture in preview, PNG and MP4.
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
    private final class PoseSet {
        let images: [CGImage]
        init(_ images: [CGImage]) { self.images = images }
        var cost: Int { images.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
    }
    private static let personalPoses: NSCache<NSString, PoseSet> = {
        let cache = NSCache<NSString, PoseSet>(); cache.countLimit = 2
        cache.totalCostLimit = 72 * 1024 * 1024; return cache
    }()
    private static let frontImages: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>(); cache.countLimit = 8
        cache.totalCostLimit = 12 * 1024 * 1024; return cache
    }()
    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// One pose keeps option changes light. A nickname never invalidates rendering.
    static func previewImage(for profile: CompanionProfile) -> CGImage? {
        if profile.isClassicAppearance { return poses.first }
        let key = profile.visualKey as NSString
        if let images = personalPoses.object(forKey: key) { return images.images.first }
        if let image = frontImages.object(forKey: key) { return image.image }
        let scene = ClayCompanionScene(profile: profile)
        guard let image = scene.image(at: 0) else { return nil }
        frontImages.setObject(ImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Commit/export only a complete set. Cancellation leaves the current look intact.
    static func prepare(_ profile: CompanionProfile) async throws {
        try Task.checkCancellation()
        if profile.isClassicAppearance {
            guard poses.count == poseCount else { throw StudioError.message("小旅伴图片不完整，请重新下载映述安装包。") }
            return
        }
        let key = profile.visualKey as NSString
        if personalPoses.object(forKey: key)?.images.count == poseCount { return }
        let scene = ClayCompanionScene(profile: profile)
        var images: [CGImage] = []
        for index in 0..<poseCount {
            try Task.checkCancellation()
            guard let image = scene.image(at: index) else {
                throw StudioError.message("暂时无法生成小旅伴造型，请重新尝试。当前造型没有改变。")
            }
            images.append(image)
            await Task.yield()
        }
        try Task.checkCancellation()
        let set = PoseSet(images)
        personalPoses.setObject(set, forKey: key, cost: set.cost)
        if let image = images.first { frontImages.setObject(ImageBox(image), forKey: key, cost: image.bytesPerRow * image.height) }
    }

    /// Opening a saved project can synchronously prepare one uncached look. Export
    /// uses the cancellable preparation above before any output is created.
    private static func images(for profile: CompanionProfile) -> [CGImage] {
        if profile.isClassicAppearance { return poses }
        let key = profile.visualKey as NSString
        if let set = personalPoses.object(forKey: key) { return set.images }
        let scene = ClayCompanionScene(profile: profile)
        let images = (0..<poseCount).compactMap { scene.image(at: $0) }
        guard images.count == poseCount else { return [] }
        let set = PoseSet(images); personalPoses.setObject(set, forKey: key, cost: set.cost)
        return images
    }

    private static let bubbles: NSCache<NSString, Bubble> = {
        let cache = NSCache<NSString, Bubble>(); cache.totalCostLimit = 32 * 1024 * 1024; return cache
    }()

    static func poseIndex(elapsed: Double?) -> Int {
        guard let elapsed, elapsed.isFinite else { return 0 }
        return max(0, min(poseCount - 1, Int(floor(max(0, elapsed) / turnDuration * Double(poseCount - 1)))))
    }

    static func layer(for caption: Caption, canvas: CGSize, localTime: Double?, companionProfile: CompanionProfile = .classic) -> CALayer {
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
        let characterPoses = images(for: companionProfile)
        if characterPoses.indices.contains(index) { character.contents = characterPoses[index] }
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
    static func animate(_ layer: CALayer, captionStart: Double, totalDuration: Double, companionProfile: CompanionProfile = .classic) {
        guard totalDuration > 0 else { return }
        let poses = images(for: companionProfile)
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

    /// A memory-pressure cache eviction may require a synchronous rebuild after
    /// preparation. Never save an export whose rebuild failed to supply a traveler.
    static func validateExportLayer(_ layer: CALayer, animated: Bool = false) throws {
        guard let character = layer.sublayers?.first(where: { $0.name == "companion-character" }),
              character.contents != nil,
              !animated || character.animation(forKey: "companion-turn") is CAKeyframeAnimation else {
            throw StudioError.message("小旅伴造型未能完整生成，整份作品尚未保存。请关闭其他占用内存的应用后重试导出。")
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

/// A small self-contained scene keeps personal characters original, local and
/// independent of external model/image downloads. No scene or PNG is saved to disk.
@MainActor private final class ClayCompanionScene {
    private let scene = SCNScene()
    private let traveler = SCNNode()
    private let head = SCNNode()
    private let renderer = SCNRenderer(device: nil, options: nil)
    private let size = CGSize(width: 512, height: 640)

    init(profile: CompanionProfile) {
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(traveler)
        let skinShade: CGFloat = profile.skinTone == .cream ? 0.14 : profile.skinTone == .peach ? 0.06 : 0
        let skin = material(profile.skinTone.color.blended(withFraction: skinShade, of: .black) ?? profile.skinTone.color)
        let hair = material(profile.hairColor.color)
        let coat = material(profile.outfitColor.color)
        let cream = material(NSColor(srgbRed: 0.89, green: 0.82, blue: 0.68, alpha: 1))
        let boots = material(NSColor(srgbRed: 0.18, green: 0.27, blue: 0.25, alpha: 1))
        let ink = material(NSColor(srgbRed: 0.12, green: 0.14, blue: 0.13, alpha: 1))
        let trim = material(profile.outfitColor.color.blended(withFraction: 0.24, of: .white) ?? profile.outfitColor.color)
        let blush = material(profile.skinTone.color.blended(withFraction: 0.30, of: NSColor(srgbRed: 0.77, green: 0.30, blue: 0.25, alpha: 1)) ?? profile.skinTone.color)
        for x: Float in [-0.25, 0.25] {
            shape(SCNCapsule(capRadius: 0.20, height: 0.64), cream, SCNVector3(x, 0.53, 0.02))
            ball(0.26, boots, SCNVector3(x, 0.22, 0.12), SCNVector3(0.91, 0.73, 1.30))
        }
        shape(SCNCapsule(capRadius: 0.50, height: 1.45), coat, SCNVector3(0, 1.30, 0), scale: SCNVector3(1, 1, 0.83))
        for sign: Float in [-1, 1] {
            let arm = shape(SCNCapsule(capRadius: 0.165, height: 0.91), coat, SCNVector3(sign * 0.59, 1.37, 0.02))
            arm.eulerAngles.z = CGFloat(sign) * 0.17
            ball(0.17, skin, SCNVector3(sign * 0.66, 0.99, 0.04), SCNVector3(0.90, 1.04, 1))
            shape(SCNBox(width: 0.24, height: 0.21, length: 0.065, chamferRadius: 0.06), trim, SCNVector3(sign * 0.25, 1.13, 0.405))
        }
        shape(SCNCapsule(capRadius: 0.018, height: 0.72), cream, SCNVector3(0, 1.50, 0.425))
        ball(0.038, boots, SCNVector3(0, 1.75, 0.455))
        shape(SCNBox(width: 0.74, height: 0.91, length: 0.39, chamferRadius: 0.18), cream, SCNVector3(0, 1.56, -0.47))
        shape(SCNBox(width: 0.52, height: 0.36, length: 0.12, chamferRadius: 0.10), trim, SCNVector3(0, 1.37, -0.70))
        for x: Float in [-0.31, 0.31] {
            shape(SCNCapsule(capRadius: 0.045, height: 0.65), cream, SCNVector3(x, 1.70, 0.365))
        }
        head.position = SCNVector3(0, 2.49, 0.02); traveler.addChildNode(head)
        let faceWidth: Float
        let faceDepth: Float
        switch profile.faceShape {
        case .round:
            faceWidth = 1.02; faceDepth = 0.94
            ball(0.66, skin, SCNVector3Zero, SCNVector3(faceWidth, 0.96, faceDepth), parent: head)
        case .oval:
            faceWidth = 0.91; faceDepth = 0.92
            ball(0.66, skin, SCNVector3Zero, SCNVector3(faceWidth, 1.04, faceDepth), parent: head)
        case .softSquare:
            faceWidth = 1.01; faceDepth = 0.94
            shape(SCNBox(width: 1.22, height: 1.18, length: 1.13, chamferRadius: 0.37), skin, SCNVector3Zero, parent: head)
        }
        let eyeZ: Float = profile.faceShape == .softSquare ? 0.584 : 0.579 * faceDepth / 0.94
        for sign: Float in [-1, 1] {
            ball(0.058, ink, SCNVector3(sign * 0.235 * faceWidth / 1.02, 0.065, eyeZ), SCNVector3(0.82, 1.15, 0.60), parent: head)
            ball(0.095, blush, SCNVector3(sign * 0.365 * faceWidth / 1.02, -0.10, eyeZ - 0.055), SCNVector3(1.12, 0.60, 0.17), parent: head)
            ball(0.13, skin, SCNVector3(sign * 0.645 * faceWidth / 1.02, -0.015, 0.01), SCNVector3(0.7, 1, 0.68), parent: head)
        }
        ball(0.065, skin, SCNVector3(0, -0.055, eyeZ + 0.057), SCNVector3(1.05, 0.85, 0.75), parent: head)
        for step in 0...14 {
            let x = Float(step) / 14 * 0.20 - 0.10
            let y = Float(-0.20) + (x * x / 0.01) * 0.042
            ball(0.013, ink, SCNVector3(x, y, eyeZ + 0.008), parent: head)
        }
        makeHair(profile.hairStyle, hair: hair, cream: cream, trim: trim, width: faceWidth, oval: profile.faceShape == .oval)
        makeGlasses(profile.glassesStyle, ink: ink, eyeZ: eyeZ)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection = true; camera.camera!.orthographicScale = 2.08
        camera.camera!.zNear = 0.1; camera.camera!.zFar = 40; camera.camera!.wantsHDR = false
        camera.position = SCNVector3(0, 2.28, 8); camera.look(at: SCNVector3(0, 1.70, 0))
        scene.rootNode.addChildNode(camera)
        light(.ambient, 100, .white, SCNVector3Zero)
        light(.omni, 290, NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1), SCNVector3(-3, 6, 5))
        light(.omni, 100, NSColor(srgbRed: 0.81, green: 0.91, blue: 1, alpha: 1), SCNVector3(4, 3, 2))
        light(.omni, 160, .white, SCNVector3(1, 4, -4))
        renderer.scene = scene; renderer.pointOfView = camera; renderer.autoenablesDefaultLighting = false
    }

    func image(at index: Int) -> CGImage? {
        let t = Double(index) / Double(CompanionStickerRenderer.poseCount - 1)
        let envelope = sin(.pi * t)
        traveler.eulerAngles.y = CGFloat(-0.18 - 0.78 * envelope * envelope)
        head.eulerAngles.y = CGFloat(-0.08 * envelope); head.eulerAngles.z = CGFloat(0.025 * envelope)
        let image = renderer.snapshot(atTime: Double(index) / 20, with: size, antialiasingMode: .multisampling4X)
        var rect = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func makeHair(_ style: CompanionHairStyle, hair: SCNMaterial, cream: SCNMaterial, trim: SCNMaterial, width: Float, oval: Bool) {
        let sx = width / 1.02
        // Hair is constructed behind the face, with separate soft fringe locks in
        // front. The open forehead keeps tiny eyes and glasses readable at sticker size.
        if style != .bucketHat && style != .bald {
            shape(hairCap(width: sx, oval: oval), hair, SCNVector3Zero, parent: head)
        }
        switch style {
        case .bucketHat:
            for sign: Float in [-1, 1] { ball(0.15, hair, SCNVector3(sign * 0.56 * sx, 0.15, 0), SCNVector3(0.75, 1.8, 1), parent: head) }
            shape(SCNCylinder(radius: 0.76, height: 0.095), cream, SCNVector3(0, 0.47, -0.025), scale: SCNVector3(1, 1, 0.90), parent: head)
            shape(SCNCylinder(radius: 0.55, height: 0.28), cream, SCNVector3(0, 0.64, -0.04), scale: SCNVector3(1, 1, 0.94), parent: head)
            shape(SCNCylinder(radius: 0.558, height: 0.065), trim, SCNVector3(0, 0.535, -0.04), scale: SCNVector3(1, 1, 0.94), parent: head)
            ball(0.55, cream, SCNVector3(0, 0.77, -0.04), SCNVector3(1, 0.25, 0.94), parent: head)
        case .short:
            for sign: Float in [-1, 1] { ball(0.16, hair, SCNVector3(sign * 0.55 * sx, 0.15, 0.01), SCNVector3(0.75, 1.7, 1), parent: head) }
            for (x, y, z, r) in [(-0.35, 0.39, 0.40, 0.22), (-0.10, 0.43, 0.46, 0.23), (0.19, 0.43, 0.43, 0.23), (0.40, 0.36, 0.34, 0.19)] {
                ball(CGFloat(r), hair, SCNVector3(Float(x) * sx, Float(y), Float(z)), SCNVector3(1, 0.65, 0.75), parent: head)
            }
        case .bob:
            for sign: Float in [-1, 1] {
                shape(SCNCapsule(capRadius: 0.20, height: 0.85), hair, SCNVector3(sign * 0.57 * sx, 0.04, 0.03), scale: SCNVector3(0.95, 1, 1.05), parent: head)
                ball(0.25, hair, SCNVector3(sign * 0.37 * sx, 0.40, 0.37), SCNVector3(1.1, 0.61, 0.75), parent: head)
            }
            ball(0.28, hair, SCNVector3(0, 0.43, 0.46), SCNVector3(1.0, 0.48, 0.60), parent: head)
        case .curls:
            for index in 0..<11 {
                let angle = Double(index) / 10 * .pi
                let x = Float(cos(angle)) * 0.58 * sx
                let y = Float(sin(angle)) * 0.40 + 0.27
                ball(0.19, hair, SCNVector3(x, y, 0.22), SCNVector3(1, 1, 1), parent: head)
            }
            for (x, y, z) in [(-0.40, 0.36, 0.46), (-0.17, 0.44, 0.51), (0.09, 0.45, 0.51), (0.34, 0.38, 0.45)] {
                ball(0.17, hair, SCNVector3(Float(x) * sx, Float(y), Float(z)), SCNVector3(1, 0.92, 0.84), parent: head)
            }
        case .bun:
            ball(0.29, hair, SCNVector3(0.05, 0.75, -0.23), SCNVector3(1, 0.88, 0.94), parent: head)
            shape(SCNTorus(ringRadius: 0.21, pipeRadius: 0.032), trim, SCNVector3(0.05, 0.63, -0.23), scale: SCNVector3(1, 1, 0.94), parent: head)
            for sign: Float in [-1, 1] { ball(0.16, hair, SCNVector3(sign * 0.54 * sx, 0.25, 0.15), SCNVector3(0.7, 1.3, 1), parent: head) }
            ball(0.25, hair, SCNVector3(-0.24 * sx, 0.43, 0.41), SCNVector3(1.5, 0.48, 0.78), parent: head)
        case .bald:
            // Two short, raised brows give the bare silhouette its own expression.
            for sign: Float in [-1, 1] {
                let brow = shape(SCNCapsule(capRadius: 0.018, height: 0.13), hair, SCNVector3(sign * 0.235 * sx, 0.22, 0.575), parent: head)
                brow.eulerAngles.z = CGFloat(sign) * 1.47
            }
        }
    }

    /// An open face cap follows the scalp rather than intersecting a full sphere
    /// with the forehead. Its back comes down to the nape, revealing real volume
    /// during the side glance without skin-colored seams between hair locks.
    private func hairCap(width: Float, oval: Bool) -> SCNGeometry {
        let segments = 64, rings = 18
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
        let ry: Float = oval ? 0.725 : 0.685
        for row in 0...rings {
            for column in 0...segments {
                let phi = Float(column) / Float(segments) * 2 * .pi
                let front = sin(phi)
                let limit: Float = front >= 0 ? 1.57 - front * 0.52 : 1.57 - front * 0.25
                let theta = Float(row) / Float(rings) * limit
                let unit = SCNVector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                let x = Float(unit.x) * 0.705 * width
                let y = Float(0.015) + Float(unit.y) * ry
                let z = Float(unit.z) * 0.66 - 0.005
                vertices.append(SCNVector3(x, y, z))
                normals.append(unit)
                if row < rings && column < segments {
                    let a = Int32(row * (segments + 1) + column), b = a + Int32(segments + 1)
                    indices.append(contentsOf: [a, a + 1, b, a + 1, b + 1, b])
                }
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    private func makeGlasses(_ style: CompanionGlassesStyle, ink: SCNMaterial, eyeZ: Float) {
        guard style != .none else { return }
        let frameZ = eyeZ + 0.072
        for sign: Float in [-1, 1] {
            let x = sign * 0.235
            if style == .round {
                let ring = shape(SCNTorus(ringRadius: 0.158, pipeRadius: 0.021), ink, SCNVector3(x, 0.065, frameZ), parent: head)
                ring.eulerAngles.x = .pi / 2
            } else {
                // A 2D stroked outline extruded into a rounded, genuinely hollow rim.
                let outline = NSBezierPath(roundedRect: CGRect(x: -18, y: -14, width: 36, height: 28), xRadius: 6.5, yRadius: 6.5)
                let inner = NSBezierPath(roundedRect: CGRect(x: -14.3, y: -10.3, width: 28.6, height: 20.6), xRadius: 3.5, yRadius: 3.5)
                outline.flatness = 0.01; inner.flatness = 0.01; outline.append(inner.reversed)
                let rim = SCNShape(path: outline, extrusionDepth: 2.2); rim.chamferRadius = 0.5
                shape(rim, ink, SCNVector3(x, 0.065, frameZ), scale: SCNVector3(0.01, 0.01, 0.01), parent: head)
            }
            // Temple arms travel around the head, staying clear of the pupils.
            let temple = shape(SCNCapsule(capRadius: 0.019, height: 0.47), ink, SCNVector3(sign * 0.43, 0.09, frameZ - 0.20), parent: head)
            temple.eulerAngles.x = .pi / 2
        }
        let bridge = shape(SCNCapsule(capRadius: 0.020, height: 0.14), ink, SCNVector3(0, 0.09, frameZ), parent: head)
        bridge.eulerAngles.z = .pi / 2
    }

    private func material(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial(); material.diffuse.contents = color
        material.lightingModel = .physicallyBased; material.roughness.contents = 0.82; material.metalness.contents = 0
        return material
    }
    @discardableResult private func shape(_ geometry: SCNGeometry, _ material: SCNMaterial, _ position: SCNVector3,
                                          scale: SCNVector3 = SCNVector3(1, 1, 1), parent: SCNNode? = nil) -> SCNNode {
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry); node.position = position; node.scale = scale
        (parent ?? traveler).addChildNode(node); return node
    }
    @discardableResult private func ball(_ radius: CGFloat, _ material: SCNMaterial, _ position: SCNVector3,
                                         _ scale: SCNVector3 = SCNVector3(1, 1, 1), parent: SCNNode? = nil) -> SCNNode {
        let sphere = SCNSphere(radius: radius); sphere.segmentCount = 48
        return shape(sphere, material, position, scale: scale, parent: parent)
    }
    private func light(_ type: SCNLight.LightType, _ intensity: CGFloat, _ color: NSColor, _ position: SCNVector3) {
        let node = SCNNode(); node.light = SCNLight(); node.light!.type = type
        node.light!.intensity = intensity; node.light!.color = color; node.position = position
        node.look(at: SCNVector3(0, 1.6, 0)); scene.rootNode.addChildNode(node)
    }
}
