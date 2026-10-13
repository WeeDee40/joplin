import ExpoModulesCore
import PencilKit
import UIKit

// A vertically growing PencilKit canvas ("endless sheet").
//
// The drawing has a fixed width in PencilKit coordinates (`canvasWidth`) and is
// zoomed to fit the view width, so a drawing looks the same on every device and
// in both orientations. This is the approach used by Apple's PencilKit sample.
class JoplinInkView: ExpoView, PKCanvasViewDelegate {
  // How much empty space is kept below the lowest stroke, so that there is
  // always room to keep writing.
  private static let overscrollHeight: CGFloat = 500
  // Margin added below the content when exporting.
  private static let exportBottomMargin: CGFloat = 24
  private static let minimumExportHeight: CGFloat = 100
  private static let exportScale: CGFloat = 2

  // Sent once the view is attached to a window. View functions (loadDrawing...)
  // can only be called after that.
  let onReady = EventDispatcher()
  let onDrawingChanged = EventDispatcher()
  private var readySent = false

  private let canvasView = PKCanvasView()
  private let backgroundImageView = UIImageView()
  private var toolPicker: PKToolPicker?

  private var canvasWidth: CGFloat = 768
  private var backgroundImage: UIImage?
  private var backgroundRect: CGRect = .zero
  private var suppressChangeEvents = false
  private var darkMode = false

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)

    clipsToBounds = true
    backgroundColor = .white

    canvasView.delegate = self
    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.alwaysBounceVertical = true
    canvasView.contentInsetAdjustmentBehavior = .never
    canvasView.showsHorizontalScrollIndicator = false
    // On iPad, `.default` follows the system setting "Only Draw with Apple Pencil"
    // (and the toggle in the tool picker): the pencil draws, a finger scrolls.
    // iPhones have no pencil, so any input draws there (scroll with two fingers).
    canvasView.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .default : .anyInput
    canvasView.tool = PKInkingTool(.pen, color: .black, width: 2)
    addSubview(canvasView)

    backgroundImageView.isUserInteractionEnabled = false
    backgroundImageView.contentMode = .scaleToFill
    backgroundImageView.isHidden = true
    // Below PencilKit's own content view, so strokes are drawn on top.
    canvasView.insertSubview(backgroundImageView, at: 0)
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    canvasView.frame = bounds
    updateZoomScale()
  }

  private func updateZoomScale() {
    guard bounds.width > 0, canvasWidth > 0 else { return }
    let scale = bounds.width / canvasWidth
    if abs(canvasView.zoomScale - scale) > 0.0001 || canvasView.minimumZoomScale != scale {
      canvasView.minimumZoomScale = scale
      canvasView.maximumZoomScale = scale
      canvasView.zoomScale = scale
    }
    updateContentSize()
  }

  private func contentBottom() -> CGFloat {
    let drawing = canvasView.drawing
    var bottom: CGFloat = 0
    if !drawing.strokes.isEmpty && !drawing.bounds.isNull {
      bottom = drawing.bounds.maxY
    }
    if backgroundImage != nil {
      bottom = max(bottom, backgroundRect.maxY)
    }
    return bottom
  }

  private func updateContentSize() {
    let zoom = canvasView.zoomScale
    let contentHeight = max(canvasView.bounds.height, (contentBottom() + Self.overscrollHeight) * zoom)
    canvasView.contentSize = CGSize(width: canvasWidth * zoom, height: contentHeight)

    backgroundImageView.frame = CGRect(
      x: backgroundRect.minX * zoom,
      y: backgroundRect.minY * zoom,
      width: backgroundRect.width * zoom,
      height: backgroundRect.height * zoom
    )
  }

  // MARK: - Tool picker

  override func didMoveToWindow() {
    super.didMoveToWindow()

    if window == nil {
      toolPicker?.setVisible(false, forFirstResponder: canvasView)
      canvasView.resignFirstResponder()
      return
    }

    if toolPicker == nil {
      let picker = PKToolPicker()
      // Remembers the selected tools/colours between sessions
      picker.stateAutosaveName = "joplin-ink"
      picker.addObserver(canvasView)
      picker.colorUserInterfaceStyle = darkMode ? .dark : .light
      picker.overrideUserInterfaceStyle = darkMode ? .dark : .light
      toolPicker = picker
    }
    toolPicker?.setVisible(true, forFirstResponder: canvasView)

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.canvasView.becomeFirstResponder()
      if !self.readySent {
        self.readySent = true
        self.onReady([:])
      }
    }
  }

  @MainActor
  func showToolPicker() {
    toolPicker?.setVisible(true, forFirstResponder: canvasView)
    canvasView.becomeFirstResponder()
  }

  // MARK: - Appearance

  func setDarkMode(_ darkMode: Bool) {
    self.darkMode = darkMode
    // PencilKit stores colours in their light-mode variant and inverts them
    // dynamically, like Apple Notes. Exports always use the light variant.
    overrideUserInterfaceStyle = darkMode ? .dark : .light
    toolPicker?.colorUserInterfaceStyle = darkMode ? .dark : .light
    toolPicker?.overrideUserInterfaceStyle = darkMode ? .dark : .light
  }

  // MARK: - PKCanvasViewDelegate

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    updateContentSize()
    if !suppressChangeEvents {
      onDrawingChanged([:])
    }
  }

  // MARK: - Loading

  @MainActor
  func loadDrawing(_ options: LoadDrawingOptions) async throws -> [String: Any] {
    suppressChangeEvents = true
    defer {
      // Changing `drawing` notifies the delegate, possibly asynchronously
      DispatchQueue.main.async { [weak self] in
        self?.suppressChangeEvents = false
      }
    }

    canvasWidth = options.canvasWidth > 0 ? CGFloat(options.canvasWidth) : 768

    var drawing = PKDrawing()
    if let base64 = options.drawingDataBase64, !base64.isEmpty {
      guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
        throw InkError.invalidDrawingData
      }
      drawing = try PKDrawing(data: data)
    }

    var result: [String: Any] = [:]
    let rect = CGRect(
      x: options.backgroundX,
      y: options.backgroundY,
      width: options.backgroundWidth,
      height: options.backgroundHeight
    )

    if let base64 = options.backgroundPngBase64, !base64.isEmpty {
      guard
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
        let image = UIImage(data: data)
      else {
        throw InkError.invalidBackground
      }
      setBackground(image, rect: rect)
    } else if let svg = options.legacySvg, !svg.isEmpty {
      guard rect.width > 0, rect.height > 0 else { throw InkError.invalidBackground }
      let rasterizer = SvgRasterizer()
      let image = try await rasterizer.rasterize(svg: svg, size: rect.size, scale: Self.exportScale, host: self)
      guard let png = image.pngData() else { throw InkError.encodingFailed }
      setBackground(image, rect: rect)
      result["background"] = [
        "pngBase64": png.base64EncodedString(),
        "x": rect.minX,
        "y": rect.minY,
        "width": rect.width,
        "height": rect.height,
      ]
    } else {
      setBackground(nil, rect: .zero)
    }

    canvasView.drawing = drawing
    canvasView.contentOffset = .zero
    setNeedsLayout()
    layoutIfNeeded()

    return result
  }

  private func setBackground(_ image: UIImage?, rect: CGRect) {
    backgroundImage = image
    backgroundRect = image == nil ? .zero : rect
    backgroundImageView.image = image
    backgroundImageView.isHidden = image == nil
    updateContentSize()
  }

  // MARK: - Export

  @MainActor
  func exportDrawing(_ options: ExportDrawingOptions) async throws -> [String: Any] {
    let drawing = canvasView.drawing
    let bottom = contentBottom()

    // Still exported when empty: the user may have erased an existing drawing.
    let isEmpty = drawing.strokes.isEmpty && backgroundImage == nil
    let size = CGSize(width: canvasWidth, height: max(Self.minimumExportHeight, ceil(bottom + Self.exportBottomMargin)))
    let rect = CGRect(origin: .zero, size: size)

    // Always render the light-mode variant of the ink: the SVG has an opaque
    // white paper layer, so it stays readable on dark themes too.
    var strokesImage = UIImage()
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
      strokesImage = drawing.image(from: rect, scale: Self.exportScale)
    }

    let backgroundImage = self.backgroundImage
    let backgroundRect = self.backgroundRect
    let drawingData = drawing.dataRepresentation()
    let exportScale = Self.exportScale

    // PNG encoding and OCR are slow, keep them off the main thread
    return try await Task.detached(priority: .userInitiated) { () -> [String: Any] in
      guard let strokesPng = strokesImage.pngData() else { throw InkError.encodingFailed }

      var result: [String: Any] = [
        "isEmpty": isEmpty,
        "width": size.width,
        "height": size.height,
        "canvasWidth": size.width,
        "strokesPngBase64": strokesPng.base64EncodedString(),
        "drawingDataBase64": drawingData.base64EncodedString(),
      ]

      if options.recognizeText {
        let format = UIGraphicsImageRendererFormat()
        format.scale = exportScale
        format.opaque = true
        let composite = UIGraphicsImageRenderer(size: size, format: format).image { context in
          UIColor.white.setFill()
          context.fill(rect)
          backgroundImage?.draw(in: backgroundRect)
          strokesImage.draw(in: rect)
        }
        if let cgImage = composite.cgImage {
          result["ocrText"] = InkTextRecognizer.recognize(cgImage, languages: options.recognitionLanguages)
        }
      }

      return result
    }.value
  }
}

enum InkError: Error, LocalizedError {
  case invalidDrawingData
  case invalidBackground
  case encodingFailed
  case rasterizationFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidDrawingData: return "The PencilKit drawing data could not be decoded."
    case .invalidBackground: return "The background image could not be decoded."
    case .encodingFailed: return "The drawing could not be encoded as PNG."
    case .rasterizationFailed(let reason): return "The existing drawing could not be rendered: \(reason)"
    }
  }
}
