import UIKit

// Text boxes and images placed on a canvas page. Their frames are stored in
// page points; `scale` converts to view points.

protocol CanvasItemView: UIView {
  var itemId: String { get }
  var itemFrame: CGRect { get set }
  var isItemSelected: Bool { get set }
  // Images keep their aspect ratio when resized
  var keepsAspectRatio: Bool { get }
  func applyLayout(scale: CGFloat)
}

// A view that only receives touches on its subviews, never on itself.
final class PassthroughView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let view = super.hitTest(point, with: event)
    return view === self ? nil : view
  }
}

private func applySelectionStyle(_ view: UIView, selected: Bool, handle: UIView) {
  view.layer.borderWidth = selected ? 1.5 : 0
  view.layer.borderColor = UIColor.systemBlue.cgColor
  handle.isHidden = !selected
}

private func makeResizeHandle() -> UIView {
  let handle = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
  handle.backgroundColor = .systemBlue
  handle.layer.cornerRadius = 7
  handle.layer.borderColor = UIColor.white.cgColor
  handle.layer.borderWidth = 2
  handle.isUserInteractionEnabled = false
  handle.isHidden = true
  return handle
}

final class CanvasTextBoxView: UIView, CanvasItemView, UITextViewDelegate {
  static let minimumWidth: CGFloat = 60
  static let defaultFontSize: Double = 16
  static let minimumFontSize: Double = 8
  static let maximumFontSize: Double = 72

  private(set) var state: CanvasTextBoxState
  let textView = UITextView()
  private let handle = makeResizeHandle()
  private var scale: CGFloat = 1

  var onChange: (() -> Void)?
  var onEndEditing: ((CanvasTextBoxView) -> Void)?

  var itemId: String { state.id }
  var keepsAspectRatio: Bool { false }
  var isEditing: Bool { textView.isFirstResponder }

  var itemFrame: CGRect {
    get { CGRect(x: state.x, y: state.y, width: state.width, height: state.height) }
    set {
      state.x = Double(newValue.minX)
      state.y = Double(newValue.minY)
      state.width = Double(max(Self.minimumWidth, newValue.width))
      updateHeight()
      applyLayout(scale: scale)
    }
  }

  var isItemSelected = false {
    didSet { applySelectionStyle(self, selected: isItemSelected, handle: handle) }
  }

  init(state: CanvasTextBoxState) {
    self.state = state
    super.init(frame: .zero)

    textView.backgroundColor = .clear
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textColor = .label
    textView.text = state.text
    textView.delegate = self
    textView.isEditable = false
    textView.isSelectable = false
    textView.isUserInteractionEnabled = false
    addSubview(textView)
    addSubview(handle)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func applyLayout(scale: CGFloat) {
    self.scale = scale
    frame = CGRect(x: state.x * scale, y: state.y * scale, width: state.width * scale, height: state.height * scale)
    textView.font = .systemFont(ofSize: CGFloat(state.fontSize) * scale)
    textView.frame = bounds
    handle.center = CGPoint(x: bounds.maxX, y: bounds.maxY)
  }

  func setFontSize(_ fontSize: Double) {
    state.fontSize = min(Self.maximumFontSize, max(Self.minimumFontSize, fontSize))
    applyLayout(scale: scale)
    updateHeight()
    applyLayout(scale: scale)
  }

  func beginEditing() {
    textView.isEditable = true
    textView.isSelectable = true
    textView.isUserInteractionEnabled = true
    textView.becomeFirstResponder()
  }

  func endEditing() {
    textView.resignFirstResponder()
  }

  private func updateHeight() {
    let font = UIFont.systemFont(ofSize: CGFloat(state.fontSize))
    let text = state.text.isEmpty ? " " : state.text
    let bounding = (text as NSString).boundingRect(
      with: CGSize(width: CGFloat(state.width), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font],
      context: nil
    )
    // A trailing newline adds an empty line that boundingRect does not count
    let extraLine = state.text.hasSuffix("\n") ? font.lineHeight : 0
    state.height = Double(ceil(bounding.height + extraLine) + 4)
  }

  // Draws the text in page points (for PNG/PDF export), always in black.
  func drawForExport() {
    let font = UIFont.systemFont(ofSize: CGFloat(state.fontSize))
    (state.text as NSString).draw(
      with: CGRect(x: state.x, y: state.y, width: state.width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font, .foregroundColor: UIColor.black],
      context: nil
    )
  }

  // MARK: - UITextViewDelegate

  func textViewDidChange(_ textView: UITextView) {
    state.text = textView.text ?? ""
    updateHeight()
    applyLayout(scale: scale)
    onChange?()
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    textView.isEditable = false
    textView.isSelectable = false
    textView.isUserInteractionEnabled = false
    onEndEditing?(self)
  }
}

final class CanvasImageItemView: UIView, CanvasItemView {
  static let minimumSize: CGFloat = 24

  private(set) var state: CanvasImageState
  let imageView = UIImageView()
  let image: UIImage
  private let handle = makeResizeHandle()
  private var scale: CGFloat = 1

  var itemId: String { state.id }
  var keepsAspectRatio: Bool { true }

  var itemFrame: CGRect {
    get { CGRect(x: state.x, y: state.y, width: state.width, height: state.height) }
    set {
      state.x = Double(newValue.minX)
      state.y = Double(newValue.minY)
      state.width = Double(max(Self.minimumSize, newValue.width))
      state.height = Double(max(Self.minimumSize, newValue.height))
      applyLayout(scale: scale)
    }
  }

  var isItemSelected = false {
    didSet { applySelectionStyle(self, selected: isItemSelected, handle: handle) }
  }

  init?(state: CanvasImageState) {
    guard
      let data = Data(base64Encoded: state.dataBase64, options: .ignoreUnknownCharacters),
      let image = UIImage(data: data)
    else { return nil }

    self.state = state
    self.image = image
    super.init(frame: .zero)

    imageView.image = image
    imageView.contentMode = .scaleToFill
    isUserInteractionEnabled = false
    addSubview(imageView)
    addSubview(handle)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func applyLayout(scale: CGFloat) {
    self.scale = scale
    frame = CGRect(x: state.x * scale, y: state.y * scale, width: state.width * scale, height: state.height * scale)
    imageView.frame = bounds
    handle.center = CGPoint(x: bounds.maxX, y: bounds.maxY)
  }

  func drawForExport() {
    image.draw(in: itemFrame)
  }

  // Creates the state for a newly inserted image: downscaled, JPEG-encoded and
  // centred around `center` (page points).
  static func makeState(for image: UIImage, center: CGPoint, maxWidth: CGFloat) -> CanvasImageState? {
    let maxPixels: CGFloat = 1600
    let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    let factor = min(1, maxPixels / max(pixelSize.width, pixelSize.height))
    let targetSize = CGSize(width: floor(pixelSize.width * factor), height: floor(pixelSize.height * factor))

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: targetSize))
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }

    let width = min(maxWidth, targetSize.width)
    let height = width * targetSize.height / max(1, targetSize.width)
    return CanvasImageState(
      id: CanvasGeometry.newId(),
      x: Double(center.x - width / 2),
      y: Double(center.y - height / 2),
      width: Double(width),
      height: Double(height),
      mime: "image/jpeg",
      dataBase64: data.base64EncodedString()
    )
  }
}
