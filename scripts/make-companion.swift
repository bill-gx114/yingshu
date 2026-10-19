import AppKit
import SceneKit
import ImageIO
import UniformTypeIdentifiers

// Original clay traveler built from rounded 3D primitives, rendered only at build time.
// Runtime previews and exports use the transparent PNGs and need no SceneKit scene.
let destination = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let scene = SCNScene()
scene.background.contents = NSColor.clear
let traveler = SCNNode(); scene.rootNode.addChildNode(traveler)
func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> SCNMaterial {
    let m = SCNMaterial(); m.diffuse.contents = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    m.lightingModel = .physicallyBased; m.roughness.contents = 0.78; m.metalness.contents = 0
    return m
}
let cream = material(0.96, 0.89, 0.74), coat = material(0.88, 0.35, 0.27)
let boots = material(0.18, 0.29, 0.28), ink = material(0.15, 0.20, 0.18)
let blush = material(0.91, 0.53, 0.41), hatBand = material(0.52, 0.62, 0.49)
@discardableResult func shape(_ geometry: SCNGeometry, _ m: SCNMaterial, _ position: SCNVector3,
                             scale: SCNVector3 = SCNVector3(1,1,1), parent: SCNNode = traveler) -> SCNNode {
    geometry.firstMaterial = m; let node = SCNNode(geometry: geometry); node.position = position; node.scale = scale
    parent.addChildNode(node); return node
}
func ball(_ radius: CGFloat, _ m: SCNMaterial, _ position: SCNVector3,
          _ scale: SCNVector3 = SCNVector3(1,1,1), parent: SCNNode = traveler) -> SCNNode {
    let sphere = SCNSphere(radius: radius); sphere.segmentCount = 64
    return shape(sphere, m, position, scale: scale, parent: parent)
}
// Little hiking boots and short cream trousers.
for x: Float in [-0.25, 0.25] {
    shape(SCNCapsule(capRadius: 0.20, height: 0.64), cream, SCNVector3(x,0.53,0.02))
    _ = ball(0.26, boots, SCNVector3(x,0.22,0.12), SCNVector3(0.91,0.73,1.30))
}
shape(SCNCapsule(capRadius: 0.50, height: 1.45), coat, SCNVector3(0,1.30,0), scale: SCNVector3(1,1,0.83))
// Arms, relaxed hands, a tiny jacket zip and two rounded pockets.
for sign: Float in [-1,1] {
    let arm = shape(SCNCapsule(capRadius: 0.165, height: 0.91), coat, SCNVector3(sign*0.59,1.37,0.02))
    arm.eulerAngles.z = CGFloat(sign) * 0.17
    _ = ball(0.17, cream, SCNVector3(sign*0.66,0.99,0.04), SCNVector3(0.90,1.04,1))
    let pocket = SCNBox(width: 0.24,height: 0.21,length: 0.065,chamferRadius: 0.06)
    shape(pocket, blush, SCNVector3(sign*0.25,1.13,0.405))
}
shape(SCNCapsule(capRadius: 0.018,height: 0.72), cream, SCNVector3(0,1.50,0.425))
_ = ball(0.038, boots, SCNVector3(0,1.75,0.455))
// A cream backpack has real depth and is revealed by the side turn.
shape(SCNBox(width: 0.74,height: 0.91,length: 0.39,chamferRadius: 0.18), cream, SCNVector3(0,1.56,-0.47))
shape(SCNBox(width: 0.52,height: 0.36,length: 0.12,chamferRadius: 0.10), hatBand, SCNVector3(0,1.37,-0.70))
for x: Float in [-0.31,0.31] {
    shape(SCNCapsule(capRadius: 0.045,height: 0.65), hatBand, SCNVector3(x,1.70,0.365))
}
let head = SCNNode(); head.position = SCNVector3(0,2.49,0.02); traveler.addChildNode(head)
_ = ball(0.66, cream, SCNVector3(0,0,0), SCNVector3(1.02,0.96,0.94), parent: head)
for sign: Float in [-1,1] {
    _ = ball(0.058, ink, SCNVector3(sign*0.235,0.065,0.579), SCNVector3(0.82,1.15,0.60), parent: head)
    _ = ball(0.095, blush, SCNVector3(sign*0.365,-0.10,0.51), SCNVector3(1.12,0.60,0.17), parent: head)
    _ = ball(0.13, cream, SCNVector3(sign*0.645,-0.015,0.01), SCNVector3(0.7,1,0.68), parent: head)
}
_ = ball(0.065, cream, SCNVector3(0,-0.055,0.636), SCNVector3(1.05,0.85,0.75), parent: head)
for step in 0...14 {
    let x = Float(step)/14 * 0.20 - 0.10
    let y = Float(-0.20) + (x*x / 0.01) * 0.042
    _ = ball(0.013, ink, SCNVector3(x,y,0.587), parent: head)
}
// A soft bucket hat, with an unmistakable front-to-side silhouette.
shape(SCNCylinder(radius: 0.76,height: 0.095), cream, SCNVector3(0,0.47,-0.025), scale: SCNVector3(1,1,0.90), parent: head)
shape(SCNCylinder(radius: 0.55,height: 0.28), cream, SCNVector3(0,0.64,-0.04), scale: SCNVector3(1,1,0.94), parent: head)
shape(SCNCylinder(radius: 0.558,height: 0.065), hatBand, SCNVector3(0,0.535,-0.04), scale: SCNVector3(1,1,0.94), parent: head)
_ = ball(0.55, cream, SCNVector3(0,0.77,-0.04), SCNVector3(1,0.25,0.94), parent: head)

let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.usesOrthographicProjection = true
camera.camera!.orthographicScale = 2.08; camera.camera!.zNear = 0.1; camera.camera!.zFar = 40
camera.camera!.wantsHDR = false
camera.position = SCNVector3(0,2.28,8); camera.look(at: SCNVector3(0,1.70,0))
scene.rootNode.addChildNode(camera)
func light(_ type: SCNLight.LightType, _ intensity: CGFloat, _ color: NSColor, _ position: SCNVector3) {
    let node = SCNNode(); node.light = SCNLight(); node.light!.type = type
    node.light!.intensity = intensity; node.light!.color = color
    node.position = position; node.look(at: SCNVector3(0,1.6,0)); scene.rootNode.addChildNode(node)
}
light(.ambient, 100, .white, SCNVector3(0,0,0))
light(.omni, 330, NSColor(srgbRed: 1,green: 0.94,blue: 0.84,alpha: 1), SCNVector3(-3,6,5))
light(.omni, 100, NSColor(srgbRed: 0.81,green: 0.91,blue: 1,alpha: 1), SCNVector3(4,3,2))
light(.omni, 180, .white, SCNVector3(1,4,-4))
let renderer = SCNRenderer(device: nil, options: nil)
renderer.scene = scene; renderer.pointOfView = camera; renderer.autoenablesDefaultLighting = false
// 25 frames at 20 fps: one curious glance to the side, then a soft return to front.
let angles: [Float] = (0..<25).map { index in
    let t = Double(index)/24
    let envelope = sin(Double.pi*t)
    return Float(-0.18 - 0.78 * envelope * envelope)
}
for (index, angle) in angles.enumerated() {
    traveler.eulerAngles.y = CGFloat(angle)
    head.eulerAngles.y = CGFloat(-0.08 * sin(Double(index)/24 * .pi))
    head.eulerAngles.z = CGFloat(0.025 * sin(Double(index)/24 * .pi))
    let image = renderer.snapshot(atTime: Double(index)/20, with: CGSize(width: 512,height: 640), antialiasingMode: .multisampling4X)
    var rect = CGRect(x:0,y:0,width:512,height:640)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
          let output = CGImageDestinationCreateWithURL(destination.appendingPathComponent(String(format:"companion-%02d.png",index)) as CFURL,
                                                       UTType.png.identifier as CFString,1,nil) else { fatalError("Cannot render traveler") }
    CGImageDestinationAddImage(output,cg,nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Cannot write traveler") }
}
print("Generated \(angles.count) original 3D clay-traveler poses at \(destination.path)")
