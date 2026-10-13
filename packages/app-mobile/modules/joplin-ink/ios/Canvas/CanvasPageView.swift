import PencilKit
import UIKit

protocol CanvasPageViewDelegate: AnyObject {
  func pageDidChange(_ page: CanvasPageView)
  func page(_ page: CanvasPageView, didSelect item: CanvasItemView?)
  func page(_ page: CanvasPageView, didEndEditing textBox: CanvasTextBoxView)
  func pageSelectedItem() -> CanvasItemView?
}

// One A4 page: paper, images, PencilKit strokes and text boxes (bottom to top).
final class CanvasPageView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
  private static let handleHitRadius: CGFloat = 28

  let pageId: String
  private(set) var template: PaperTemplate
  let canvasView = PKCanvasView()
  private let paperView = PaperView()
  private let imagesLayer = PassthroughView()
  private let textLayer = PassthroughView()
  private(set) var textBoxes: [CanvasTextBoxView] = []
  private(set) var images: [CanvasImageItemView] = []
  private(set) var scale: CGFloat = 1

  // Changed since the last save / since the last text recognition
  var dirtySinceSave = false
  var dirtySinceRecognition = false
  private var suppressChanges = false

  weak var delegate: CanvasPageViewDelegate?

  let itemPan = UIPanGestureRecognizer()
  private let itemTap = UITapGestureRecognizer()
  private let itemPinch = UIPinchGestureRecognizer()

  private enum DragMode { case move, resize }
  private var dragMode: DragMode = .move
  private var dragItem: CanvasItemView?
  private var dragStartFrame: CGRect = .zero
  private var pinchStartFrame: CGRect = .zero

  init(state: CanvasPageState) throws {
    pageId = state.id
    template = state.template
    super.init(frame: .zero)

    clipsToBounds = true
    accessibilityLabel = "Page"

    paperView.template = template
    addSubview(paperView)
    addSubview(imagesLayer)

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.isScrollEnabled = false
    canvasView.showsVerticalScrollIndicator = false
    canvasView.showsHorizontalScrollIndicator = false
    canvasView.contentInsetAdjustmentBehavior = .never
    canvasView.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .default : .anyInput
    canvasView.delegate = self
    addSubview(canvasView)
    addSubview(textLayer)

    suppressChanges = true
    if !state.drawingDataBase64.isEmpty {
      guard let data = Data(base64Encoded: state.drawingDataBase64, options: .ignoreUnknownCharacters) else {
        throw CanvasError.invalidDrawingData
      }
      canvasView.drawing = try PKDrawing(data: data)
    }
    for imageState in state.images {
      if let view = CanvasImageItemView(state: imageState) {
        images.append(view)
        imagesLayer.addSubview(view)
      }
    }
    for textState in state.textBoxes {
      addTextBoxView(CanvasTextBoxView(state: textState))
    }
    suppressChanges = false

    for recognizer in [itemPan, itemTap, itemPinch] as [UIGestureRecognizer] {
      recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      recognizer.delegate = self
      addGestureRecognizer(recognizer)
    }
    itemPan.addTarget(self, action: #selector(onItemPan(_:)))
    itemPan.maximumNumberOfTouches = 1
    itemTap.addTarget(self, action: #selector(onItemTap(_:)))
    itemPinch.addTarget(self, action: #selector(onItemPinch(_:)))
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Layout

  func applyScale(_ scale: CGFloat) {
    self.scale = scale
    let size = CGSize(width: CanvasGeometry.pageSize.width * scale, height: CanvasGeometry.pageSize.height * scale)
    for view in [paperView, imagesLayer, canvasView, textLayer] as [UIView] {
      view.frame = CGRect(origin: .zero, size: size)
    }
    paperView.scale = scale

    canvasView.minimumZoomScale = scale
    canvasView.maximumZoomScale = scale
    canvasView.zoomScale = scale
    canvasView.contentSize = size
    canvasView.contentOffset = .zero

    for item in allItems { item.applyLayout(scale: scale) }
  }

  // Images and text boxes, bottom to top
  var allItems: [CanvasItemView] {
    return (images as [CanvasItemView]) + (textBoxes as [CanvasItemView])
  }

  // MARK: - Content

  func setTemplate(_ template: PaperTemplate) {
    guard template != self.template else { return }
    self.template = template
    paperView.template = template
    markChanged()
  }

  @discardableResult
  func addTextBox(center: CGPoint) -> CanvasTextBoxView {
    let width: CGFloat = 300
    let state = CanvasTextBoxState(
      id: CanvasGeometry.newId(),
      x: Double(max(16, min(CanvasGeometry.pageSize.width - width - 16, center.x - width / 2))),
      y: Double(max(16, center.y)),
      width: Double(width),
      height: CanvasTextBoxView.defaultFontSize * 1.5,
      text: "",
      fontSize: CanvasTextBoxView.defaultFontSize
    )
    let view = CanvasTextBoxView(state: state)
    addTextBoxView(view)
    view.applyLayout(scale: scale)
    markChanged()
    return view
  }

  func addImage(_ image: UIImage, center: CGPoint) -> CanvasImageItemView? {
    guard
      let state = CanvasImageItemView.makeState(for: image, center: center, maxWidth: CanvasGeometry.pageSize.width * 0.7),
      let view = CanvasImageItemView(state: state)
    else { return nil }
    images.append(view)
    imagesLayer.addSubview(view)
    view.applyLayout(scale: scale)
    markChanged()
    return view
  }

  func remove(_ item: CanvasItemView) {
    item.removeFromSuperview()
    textBoxes.removeAll { $0 === item }
    images.removeAll { $0 === item }
    markChanged()
  }

  func contains(_ item: CanvasItemView) -> Bool {
    return allItems.contains { $0 === item }
  }

  private func addTextBoxView(_ view: CanvasTextBoxView) {
    view.onChange = { [weak self] in self?.markChanged() }
    view.onEndEditing = { [weak self] textBox in
      guard let self else { return }
      self.delegate?.page(self, didEndEditing: textBox)
    }
    textBoxes.append(view)
    textLayer.addSubview(view)
  }

  func markChanged() {
    guard !suppressChanges else { return }
    dirtySinceSave = true
    dirtySinceRecognition = true
    delegate?.pageDidChange(self)
  }

  // Plain text of all text boxes, top to bottom (for search)
  var textContent: String {
    return textBoxes
      .sorted { $0.state.y == $1.state.y ? $0.state.x < $1.state.x : $0.state.y < $1.state.y }
      .map { $0.state.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  func makeState() -> CanvasPageState {
    return CanvasPageState(
      id: pageId,
      template: template,
      drawingDataBase64: canvasView.drawing.dataRepresentation().base64EncodedString(),
      textBoxes: textBoxes.map { $0.state },
      images: images.map { $0.state }
    )
  }

  // MARK: - Export

  // Draws the page in page points into the current context, always in light mode:
  // paper, images, strokes, text.
  func drawForExport(in context: CGContext, strokesScale: CGFloat) {
    PaperRenderer.draw(template, in: context, scale: 1, colors: PaperRenderer.lightColors)
    for image in images { image.drawForExport() }

    var strokes = UIImage()
    let drawing = canvasView.drawing
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
      strokes = drawing.image(from: CanvasGeometry.pageRect, scale: strokesScale)
    }
    strokes.draw(in: CanvasGeometry.pageRect)

    for textBox in textBoxes { textBox.drawForExport() }
  }

  func renderImage(scale renderScale: CGFloat) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = renderScale
    format.opaque = true
    return UIGraphicsImageRenderer(size: CanvasGeometry.pageSize, format: format).image { context in
      drawForExport(in: context.cgContext, strokesScale: renderScale)
    }
  }

  // MARK: - PKCanvasViewDelegate

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    markChanged()
  }

  // MARK: - Item gestures (finger only)

  private func pagePoint(_ viewPoint: CGPoint) -> CGPoint {
    return CGPoint(x: viewPoint.x / scale, y: viewPoint.y / scale)
  }

  private func item(at viewPoint: CGPoint) -> CanvasItemView? {
    for textBox in textBoxes.reversed() where textBox.frame.insetBy(dx: -8, dy: -8).contains(viewPoint) {
      return textBox
    }
    for image in images.reversed() where image.frame.contains(viewPoint) {
      return image
    }
    return nil
  }

  private func isOnResizeHandle(_ item: CanvasItemView, viewPoint: CGPoint) -> Bool {
    guard item.isItemSelected else { return false }
    let corner = CGPoint(x: item.frame.maxX, y: item.frame.maxY)
    return hypot(viewPoint.x - corner.x, viewPoint.y - corner.y) < Self.handleHitRadius
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    let location = gestureRecognizer.location(in: self)

    // Items must be selected (tapped) first, so that scrolling over them never
    // moves them by accident.
    guard let selected = delegate?.pageSelectedItem(), contains(selected) else {
      return gestureRecognizer === itemTap ? super.gestureRecognizerShouldBegin(gestureRecognizer) : false
    }

    if gestureRecognizer === itemPan {
      if isOnResizeHandle(selected, viewPoint: location) { return true }
      guard item(at: location) === selected else { return false }
      if let textBox = selected as? CanvasTextBoxView, textBox.isEditing { return false }
      return true
    }

    if gestureRecognizer === itemPinch {
      return selected is CanvasImageItemView && selected.frame.insetBy(dx: -40, dy: -40).contains(location)
    }

    return super.gestureRecognizerShouldBegin(gestureRecognizer)
  }

  // A tap selects/deselects items even if a finger is also allowed to draw.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return gestureRecognizer === itemTap
  }

  // Lets the outer scroll view's pan and zoom wait for item drags/pinches.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    guard otherGestureRecognizer.view is UIScrollView, otherGestureRecognizer.view !== canvasView else { return false }
    if gestureRecognizer === itemPan { return otherGestureRecognizer is UIPanGestureRecognizer }
    if gestureRecognizer === itemPinch { return otherGestureRecognizer is UIPinchGestureRecognizer }
    return false
  }

  @objc private func onItemTap(_ recognizer: UITapGestureRecognizer) {
    let location = recognizer.location(in: self)
    guard let item = item(at: location) else {
      delegate?.page(self, didSelect: nil)
      return
    }
    if let textBox = item as? CanvasTextBoxView, textBox.isItemSelected {
      if !textBox.isEditing { textBox.beginEditing() }
      return
    }
    delegate?.page(self, didSelect: item)
  }

  @objc private func onItemPan(_ recognizer: UIPanGestureRecognizer) {
    let location = recognizer.location(in: self)

    switch recognizer.state {
    case .began:
      if let selected = delegate?.pageSelectedItem(), contains(selected), isOnResizeHandle(selected, viewPoint: location) {
        dragItem = selected
        dragMode = .resize
      } else {
        dragItem = item(at: location)
        dragMode = .move
      }
      guard let dragItem else { return }
      delegate?.page(self, didSelect: dragItem)
      dragStartFrame = dragItem.itemFrame

    case .changed:
      guard let dragItem else { return }
      let translation = recognizer.translation(in: self)
      let dx = translation.x / scale
      let dy = translation.y / scale
      var frame = dragStartFrame

      switch dragMode {
      case .move:
        frame.origin.x = clamp(frame.origin.x + dx, min: -frame.width / 2, max: CanvasGeometry.pageSize.width - frame.width / 2)
        frame.origin.y = clamp(frame.origin.y + dy, min: -frame.height / 2, max: CanvasGeometry.pageSize.height - frame.height / 2)
      case .resize:
        let width = max(24, dragStartFrame.width + dx)
        frame.size.width = width
        if dragItem.keepsAspectRatio {
          frame.size.height = width * dragStartFrame.height / max(1, dragStartFrame.width)
        }
      }
      dragItem.itemFrame = frame
      delegate?.page(self, didSelect: dragItem)

    case .ended, .cancelled:
      if dragItem != nil { markChanged() }
      dragItem = nil

    default:
      break
    }
  }

  @objc private func onItemPinch(_ recognizer: UIPinchGestureRecognizer) {
    switch recognizer.state {
    case .began:
      guard let image = delegate?.pageSelectedItem() as? CanvasImageItemView, contains(image) else { return }
      dragItem = image
      pinchStartFrame = image.itemFrame
      delegate?.page(self, didSelect: image)
    case .changed:
      guard let dragItem else { return }
      let width = max(CanvasImageItemView.minimumSize, pinchStartFrame.width * recognizer.scale)
      let height = width * pinchStartFrame.height / max(1, pinchStartFrame.width)
      dragItem.itemFrame = CGRect(
        x: pinchStartFrame.midX - width / 2,
        y: pinchStartFrame.midY - height / 2,
        width: width,
        height: height
      )
      delegate?.page(self, didSelect: dragItem)
    case .ended, .cancelled:
      if dragItem != nil { markChanged() }
      dragItem = nil
    default:
      break
    }
  }

  private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    return Swift.min(maxValue, Swift.max(minValue, value))
  }
}
