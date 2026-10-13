import UIKit

// Draws the paper (background colour and lines/grid) of a page.
// Used for the on-screen paper as well as for PNG and PDF export.
enum PaperRenderer {
  // Lined paper: ~8.5 mm line spacing, starting below a top margin
  static let lineSpacing: CGFloat = 24
  static let linedTopMargin: CGFloat = 72
  // Grid paper: same spacing as the lines of lined paper
  static let gridSpacing: CGFloat = lineSpacing

  struct Colors {
    let paper: UIColor
    let line: UIColor
  }

  static let lightColors = Colors(
    paper: .white,
    line: UIColor(red: 0.78, green: 0.84, blue: 0.90, alpha: 1)
  )

  static let darkColors = Colors(
    paper: UIColor(white: 0.12, alpha: 1),
    line: UIColor(white: 0.28, alpha: 1)
  )

  // `scale` converts page points to the coordinate space of `context`.
  static func draw(
    _ template: PaperTemplate,
    in context: CGContext,
    scale: CGFloat,
    colors: Colors
  ) {
    let size = CGSize(width: CanvasGeometry.pageSize.width * scale, height: CanvasGeometry.pageSize.height * scale)

    context.saveGState()
    context.setFillColor(colors.paper.cgColor)
    context.fill(CGRect(origin: .zero, size: size))

    context.setStrokeColor(colors.line.cgColor)
    context.setLineWidth(max(0.5, 0.6 * scale))

    switch template {
    case .blank:
      break
    case .lined:
      var y = linedTopMargin
      while y < CanvasGeometry.pageSize.height - 24 {
        context.move(to: CGPoint(x: 0, y: y * scale))
        context.addLine(to: CGPoint(x: size.width, y: y * scale))
        y += lineSpacing
      }
      context.strokePath()
    case .grid:
      var x = gridSpacing
      while x < CanvasGeometry.pageSize.width {
        context.move(to: CGPoint(x: x * scale, y: 0))
        context.addLine(to: CGPoint(x: x * scale, y: size.height))
        x += gridSpacing
      }
      var y = gridSpacing
      while y < CanvasGeometry.pageSize.height {
        context.move(to: CGPoint(x: 0, y: y * scale))
        context.addLine(to: CGPoint(x: size.width, y: y * scale))
        y += gridSpacing
      }
      context.strokePath()
    }

    context.restoreGState()
  }
}

// Tiles the paper drawing, so that a zoomed-in page does not need one huge bitmap.
private final class PaperTiledLayer: CATiledLayer {
  override class func fadeDuration() -> CFTimeInterval { 0 }
}

// On-screen paper. Follows light/dark mode.
final class PaperView: UIView {
  override class var layerClass: AnyClass { PaperTiledLayer.self }

  // Read from the tile drawing threads, so they are plain stored values
  // (UIKit state like traitCollection must not be used there).
  private struct DrawingState {
    var template: PaperTemplate = .blank
    var scale: CGFloat = 1
    var colors = PaperRenderer.lightColors
  }
  private let stateLock = NSLock()
  private var drawingState = DrawingState()

  private func updateState(_ change: (inout DrawingState) -> Void) {
    stateLock.lock()
    change(&drawingState)
    stateLock.unlock()
    setNeedsDisplay()
  }

  var template: PaperTemplate = .blank {
    didSet { updateState { $0.template = template } }
  }
  var scale: CGFloat = 1 {
    didSet { updateState { $0.scale = scale } }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = true
    isUserInteractionEnabled = false
    contentMode = .redraw
    (layer as? CATiledLayer)?.tileSize = CGSize(width: 512, height: 512)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    stateLock.lock()
    let state = drawingState
    stateLock.unlock()
    PaperRenderer.draw(state.template, in: context, scale: state.scale, colors: state.colors)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    let isDark = traitCollection.userInterfaceStyle == .dark
    updateState { $0.colors = isDark ? PaperRenderer.darkColors : PaperRenderer.lightColors }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    let isDark = traitCollection.userInterfaceStyle == .dark
    updateState { $0.colors = isDark ? PaperRenderer.darkColors : PaperRenderer.lightColors }
  }
}
