import AppKit
import Foundation

let root = CommandLine.arguments[1]
let folder = URL(fileURLWithPath: root).appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func draw(_ pixels: Int, file: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let colors = [NSColor(calibratedRed: 0.11, green: 0.1, blue: 0.24, alpha: 1).cgColor, NSColor(calibratedRed: 0.44, green: 0.29, blue: 0.9, alpha: 1).cgColor]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0,y: 0), end: CGPoint(x: 1024,y: 1024), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
    cg.setStrokeColor(NSColor(calibratedRed: 0.7, green: 1, blue: 0.78, alpha: 1).cgColor)
    cg.setLineCap(.round); cg.setLineWidth(62)
    for (x,height) in [(310.0,120.0),(445,310),(580,440),(715,210)] {
        cg.move(to: CGPoint(x:x,y:512-height/2)); cg.addLine(to:CGPoint(x:x,y:512+height/2));cg.strokePath()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(file))
}
var entries: [[String:String]] = []
for (size, scale) in [(20,2),(20,3),(29,2),(29,3),(40,2),(40,3),(60,2),(60,3)] {
    let name = "icon-\(size)-\(scale).png"
    try draw(size * scale, file: name)
    entries.append(["idiom":"iphone","size":"\(size)x\(size)","scale":"\(scale)x","filename":name])
}
try draw(1024, file:"icon-1024.png")
entries.append(["idiom":"ios-marketing","size":"1024x1024","scale":"1x","filename":"icon-1024.png"])
try JSONSerialization.data(withJSONObject:["images":entries,"info":["author":"xcode","version":1]],options:.prettyPrinted).write(to: folder.appendingPathComponent("Contents.json"))
