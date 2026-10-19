import AppKit
import WebKit

// Render repository-owned SVGs only. No desktop, microphone, project or account access.
final class ShowcaseRenderer: NSObject, WKNavigationDelegate {
    let view = WKWebView(frame: .zero)
    let root: URL
    var queue = ["hero", "workflow", "captions", "exports", "architecture"]
    var name = ""
    init(root: URL) { self.root = root; super.init(); view.navigationDelegate = self }
    func next() {
        guard !queue.isEmpty else { print("Rendered all 5 showcase PNGs"); exit(0) }
        name = queue.removeFirst()
        let url = root.appendingPathComponent("\(name).svg")
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let pattern = #"width="(\d+)" height="(\d+)""#
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let wr = Range(match.range(at: 1), in: source), let hr = Range(match.range(at: 2), in: source),
                  let width = Double(source[wr]), let height = Double(source[hr]) else { throw NSError(domain: "SVG dimensions", code: 1) }
            view.setFrameSize(NSSize(width: width, height: height))
            view.loadFileURL(url, allowingReadAccessTo: root)
        } catch { fputs("Cannot load showcase SVG: \(error)\n", stderr); exit(1) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let config = WKSnapshotConfiguration(); config.rect = webView.bounds
            webView.takeSnapshot(with: config) { image, error in
                do {
                    guard let image = image, let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) else { throw error ?? NSError(domain: "PNG snapshot", code: 1) }
                    try png.write(to: self.root.appendingPathComponent("\(self.name).png"), options: .atomic)
                    print("Rendered \(self.name).png")
                    self.next()
                } catch { fputs("Showcase render failed: \(error)\n", stderr); exit(1) }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fputs("Showcase navigation failed: \(error)\n", stderr); exit(1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/showcase")
let renderer = ShowcaseRenderer(root: root)
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { fputs("Showcase render timed out\n", stderr); exit(1) }
renderer.next()
app.run()
