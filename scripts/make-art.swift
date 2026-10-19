import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
func color(_ hex: UInt32) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func path(_ points: [CGPoint], _ c: NSColor) {
    let p = NSBezierPath(); p.move(to: points[0]); points.dropFirst().forEach { p.line(to: $0) }; p.close(); c.setFill(); p.fill()
}
func ellipse(_ rect: CGRect, _ c: NSColor) { c.setFill(); NSBezierPath(ovalIn: rect).fill() }
func png(_ name: String, size: CGSize, draw: () -> Void) {
    let image = NSImage(size: size)
    image.lockFocus(); draw(); image.unlockFocus()
    let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! data.write(to: root.appendingPathComponent(name))
}
let size = CGSize(width: 1600, height: 1000)
png("demo-coast.png", size: size) {
    NSGradient(starting: color(0xE7E5CC), ending: color(0x82B8B3))!.draw(in: CGRect(origin: .zero, size: size), angle: 90)
    ellipse(CGRect(x: 1140, y: 700, width: 150, height: 150), color(0xF7E5AF))
    color(0x4F9398).setFill(); CGRect(x: 0, y: 0, width: 1600, height: 590).fill()
    path([.init(x: 0,y: 0),.init(x: 1600,y: 0),.init(x: 1600,y: 290),.init(x: 1300,y: 360),.init(x: 950,y: 285),.init(x: 580,y: 380),.init(x: 0,y: 510)], color(0xDCC8A2))
    path([.init(x: 0,y: 0),.init(x: 620,y: 0),.init(x: 480,y: 150),.init(x: 360,y: 190),.init(x: 290,y: 340),.init(x: 0,y: 430)], color(0x52695B))
    for i in 0..<8 {
        let p = NSBezierPath(); p.move(to: .init(x: 470 + i * 145, y: 445 + (i % 3) * 25)); p.curve(to: .init(x: 620 + i * 145, y: 440 + (i % 3) * 25), controlPoint1: .init(x: 530 + i * 145, y: 455 + (i % 3) * 25), controlPoint2: .init(x: 570 + i * 145, y: 430 + (i % 3) * 25)); color(0xCEE2D8).withAlphaComponent(0.6).setStroke(); p.lineWidth = 3; p.stroke()
    }
    path([.init(x: 1100,y: 610),.init(x: 1130,y: 590),.init(x: 1160,y: 610)], color(0x567678))
}
png("demo-hills.png", size: size) {
    NSGradient(starting: color(0xFAE9BD), ending: color(0xBDD5CF))!.draw(in: CGRect(origin: .zero, size: size), angle: 90)
    ellipse(CGRect(x: 300, y: 720, width: 140, height: 140), color(0xFFF6CC))
    path([.init(x: 0,y: 0),.init(x: 0,y: 420),.init(x: 380,y: 700),.init(x: 700,y: 400),.init(x: 1100,y: 640),.init(x: 1600,y: 380),.init(x: 1600,y: 0)], color(0x95AC8C))
    path([.init(x: 0,y: 0),.init(x: 0,y: 320),.init(x: 520,y: 520),.init(x: 950,y: 260),.init(x: 1380,y: 500),.init(x: 1600,y: 340),.init(x: 1600,y: 0)], color(0x5F805F))
    path([.init(x: 0,y: 0),.init(x: 650,y: 0),.init(x: 800,y: 180),.init(x: 910,y: 300),.init(x: 880,y: 340),.init(x: 750,y: 225),.init(x: 480,y: 0)], color(0xE8D2A2))
    for i in 0..<7 {
        let x = CGFloat(110 + i * 210), y = CGFloat(100 + (i % 3) * 38)
        color(0x4A6651).setFill(); CGRect(x: x, y: y, width: 15, height: 85).fill()
        ellipse(CGRect(x: x - 34, y: y + 45, width: 85, height: 110), color(0x3D624D))
    }
}
png("demo-evening.png", size: size) {
    NSGradient(starting: color(0xEDB890), ending: color(0x8E9EB0))!.draw(in: CGRect(origin: .zero, size: size), angle: 90)
    ellipse(CGRect(x: 965, y: 430, width: 220, height: 220), color(0xFFD497))
    path([.init(x: 0,y: 0),.init(x: 0,y: 400),.init(x: 350,y: 520),.init(x: 740,y: 325),.init(x: 1200,y: 500),.init(x: 1600,y: 380),.init(x: 1600,y: 0)], color(0x777C88))
    color(0x556D75).setFill(); CGRect(x: 0, y: 0, width: 1600, height: 320).fill()
    for i in 0..<12 { color(0xE7B893).withAlphaComponent(0.42).setFill(); CGRect(x: 950 - CGFloat(i * 6), y: CGFloat(275 - i * 18), width: CGFloat(160 + i * 12), height: 5).fill() }
    path([.init(x: 0,y: 0),.init(x: 0,y: 185),.init(x: 370,y: 140),.init(x: 580,y: 0)], color(0x34484B))
    color(0x34484B).setFill(); CGRect(x: 230, y: 130, width: 14, height: 395).fill()
    path([.init(x: 240,y: 560),.init(x: 90,y: 375),.init(x: 390,y: 375)], color(0x34484B))
    path([.init(x: 240,y: 470),.init(x: 60,y: 265),.init(x: 420,y: 265)], color(0x34484B))
}
png("AppIcon.png", size: CGSize(width: 1024, height: 1024)) {
    let rect = CGRect(x: 30, y: 30, width: 964, height: 964)
    let p = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
    NSGradient(starting: color(0xE8886B), ending: color(0xC55845))!.draw(in: p, angle: 70)
    color(0xFFF6E8).setFill(); NSBezierPath(roundedRect: CGRect(x: 220, y: 275, width: 584, height: 474), xRadius: 80, yRadius: 80).fill()
    path([.init(x: 425,y: 390),.init(x: 425,y: 630),.init(x: 635,y: 510)], color(0xCA644D))
    color(0xFFF6E8).setFill(); NSBezierPath(roundedRect: CGRect(x: 580, y: 165, width: 220, height: 130), xRadius: 55, yRadius: 55).fill()
    for i in 0..<3 { ellipse(CGRect(x: 618 + i * 50, y: 220, width: 22, height: 22), color(0xCA644D)) }
}
print("Generated original demonstration illustrations and app icon.")
