import AppKit
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let source = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Could not read the square icon artwork")
}

func cornerPoint(_ t: CGFloat, inset: CGFloat, radius: CGFloat) -> CGPoint {
    // Quintic Bézier with the first and last three points collinear.
    // Its endpoint curvature is zero, matching the adjacent straight edges.
    let inner = radius * 0.24
    let outer = radius * 0.62
    let u = 1 - t
    func coordinate(_ fraction: CGFloat, _ complement: CGFloat) -> CGFloat {
        inset + radius * pow(fraction, 5)
            + 5 * outer * pow(fraction, 4) * complement
            + 10 * inner * pow(fraction, 3) * pow(complement, 2)
    }
    return CGPoint(x: coordinate(u, t), y: coordinate(t, u))
}

func silhouette() -> CGPath {
    let edge: CGFloat = 100
    let radius: CGFloat = 235
    let points = (0...256).map { cornerPoint(CGFloat($0) / 256, inset: edge, radius: radius) }
    let path = CGMutablePath()
    let width: CGFloat = 1024
    path.move(to: points[0])
    for point in points.dropFirst() { path.addLine(to: point) }
    for point in points.reversed() { path.addLine(to: CGPoint(x: point.x, y: width - point.y)) }
    for point in points { path.addLine(to: CGPoint(x: width - point.x, y: width - point.y)) }
    for point in points.reversed() { path.addLine(to: CGPoint(x: width - point.x, y: point.y)) }
    path.closeSubpath()
    return path
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    // Render the mask above target resolution so the small icons retain a clean edge.
    let workingSize = max(pixels, 256)
    guard let context = CGContext(data: nil, width: workingSize, height: workingSize, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not allocate the icon canvas")
    }
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(workingSize) / 1024, y: CGFloat(workingSize) / 1024)
    context.addPath(silhouette())
    context.clip()
    context.draw(image, in: CGRect(x: 100, y: 100, width: 824, height: 824))
    guard let rendered = context.makeImage() else { fatalError("Could not render the icon") }
    let bitmap: CGImage
    if workingSize == pixels {
        bitmap = rendered
    } else {
        guard let scaled = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not allocate the icon rendition")
        }
        scaled.interpolationQuality = .high
        scaled.draw(rendered, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let resized = scaled.makeImage() else { fatalError("Could not resize the icon") }
        bitmap = resized
    }
    let url = destination.appendingPathComponent("\(pixels).png")
    guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Could not create an icon rendition") }
    CGImageDestinationAddImage(output, bitmap, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Could not write the icon rendition") }
}
