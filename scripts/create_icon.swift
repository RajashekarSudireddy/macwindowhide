import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func image(_ size: Int, name: String) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setFillColor(CGColor(red: 0.09, green: 0.12, blue: 0.13, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 34, y: 34, width: 956, height: 956), cornerWidth: 210, cornerHeight: 210, transform: nil))
    context.fillPath()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(32)
    context.setStrokeColor(CGColor(red: 0.48, green: 0.66, blue: 0.64, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 190, y: 340, width: 530, height: 390), cornerWidth: 40, cornerHeight: 40, transform: nil))
    context.strokePath()
    context.setFillColor(CGColor(red: 0.09, green: 0.12, blue: 0.13, alpha: 1))
    context.fill(CGRect(x: 290, y: 260, width: 540, height: 390))
    context.setStrokeColor(CGColor(red: 0.89, green: 0.94, blue: 0.92, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 290, y: 260, width: 540, height: 390), cornerWidth: 40, cornerHeight: 40, transform: nil))
    context.strokePath()
    context.move(to: CGPoint(x: 295, y: 564)); context.addLine(to: CGPoint(x: 825, y: 564)); context.strokePath()
    context.setFillColor(CGColor(red: 0.87, green: 0.43, blue: 0.36, alpha: 1))
    context.fillEllipse(in: CGRect(x: 713, y: 590, width: 28, height: 28))
    context.setStrokeColor(CGColor(red: 0.48, green: 0.66, blue: 0.64, alpha: 1))
    context.setLineWidth(39)
    context.move(to: CGPoint(x: 390, y: 350)); context.addLine(to: CGPoint(x: 717, y: 488)); context.strokePath()
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name).appendingPathExtension("png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon") }
}
for points in [16, 32, 128, 256, 512] {
    try image(points, name: "icon_\(points)x\(points)")
    try image(points * 2, name: "icon_\(points)x\(points)@2x")
}
print(directory.path)
