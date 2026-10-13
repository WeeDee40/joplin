import ExpoModulesCore
import PencilKit
import PhotosUI
import UIKit

// Canvas note editor: A4 pages below each other, PencilKit strokes, text boxes
// and images. State is exchanged with JavaScript as JSON (see CanvasModels).
class JoplinCanvasView: ExpoView, UIScrollViewDelegate, CanvasPageViewDelegate {
  private static let pageSpacing: CGFloat = 24
  private static let sideMargin: CGFloat = 16
  private static let maximumPageWidth: CGFloat = 900
  private static let exportScale: CGFloat = 2

  let onReady = EventDispatcher()
  let onChanged = EventDispatcher()
  let onStateChanged = EventDispatcher()

  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private var pages: [CanvasPageView] = []
  private var toolPicker: PKToolPicker?
  private var readySent = false
  private var darkMode = false

  private weak var selectedItem: CanvasItemView?
  private weak var selectedPage: CanvasPageView?
  private let selectionToolbar = UIStackView()
  private var pendingImagePage: CanvasPageView?
  private var imagePicker: ImagePickerCoordinator?
  private var lastReportedState: [String: Any] = [:]

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)

    backgroundColor = .systemGroupedBackground
    clipsToBounds = true

    scrollView.delegate = self
    scrollView.alwaysBounceVertical = true
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.keyboardDismissMode = .interactive
    // Tapping the status bar would jump to the first page
    scrollView.scrollsToTop = false
    addSubview(scrollView)
    scrollView.addSubview(contentView)

    selectionToolbar.axis = .horizontal
    selectionToolbar.spacing = 4
    selectionToolbar.isLayoutMarginsRelativeArrangement = true
    selectionToolbar.layoutMargins = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    selectionToolbar.backgroundColor = .secondarySystemBackground
    selectionToolbar.layer.cornerRadius = 10
    selectionToolbar.layer.shadowColor = UIColor.black.cgColor
    selectionToolbar.layer.shadowOpacity = 0.15
    selectionToolbar.layer.shadowRadius = 6
    selectionToolbar.layer.shadowOffset = CGSize(width: 0, height: 2)
    selectionToolbar.isHidden = true

    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillHide(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    layoutPages()
  }

  private var pageScale: CGFloat {
    let available = min(Self.maximumPageWidth, bounds.width - 2 * Self.sideMargin)
    return max(0.1, available / CanvasGeometry.pageSize.width)
  }

  private func layoutPages() {
    guard bounds.width > 0 else { return }
    let scale = pageScale
    let pageSize = CGSize(width: CanvasGeometry.pageSize.width * scale, height: CanvasGeometry.pageSize.height * scale)
    let x = (bounds.width - pageSize.width) / 2
    var y = Self.pageSpacing

    for page in pages {
      page.frame = CGRect(origin: CGPoint(x: x, y: y), size: pageSize)
      if abs(page.scale - scale) > 0.0001 || page.canvasView.frame.size != pageSize {
        page.applyScale(scale)
      }
      y += pageSize.height + Self.pageSpacing
    }

    contentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: y)
    scrollView.contentSize = contentView.frame.size
    updateSelectionToolbar()
  }

  // MARK: - Tool picker

  override func didMoveToWindow() {
    super.didMoveToWindow()

    guard window != nil else {
      for page in pages {
        toolPicker?.setVisible(false, forFirstResponder: page.canvasView)
      }
      return
    }

    if toolPicker == nil {
      let picker = PKToolPicker()
      picker.stateAutosaveName = "joplin-ink"
      picker.colorUserInterfaceStyle = darkMode ? .dark : .light
      picker.overrideUserInterfaceStyle = darkMode ? .dark : .light
      toolPicker = picker
      for page in pages { attachToolPicker(to: page) }
    }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.activateCurrentCanvas()
      if !self.readySent {
        self.readySent = true
        self.onReady([:])
      }
    }
  }

  private func attachToolPicker(to page: CanvasPageView) {
    guard let toolPicker else { return }
    toolPicker.addObserver(page.canvasView)
    toolPicker.setVisible(true, forFirstResponder: page.canvasView)
    page.canvasView.tool = toolPicker.selectedTool
  }

  @MainActor
  func activateCurrentCanvas() {
    guard let page = currentPage else { return }
    toolPicker?.setVisible(true, forFirstResponder: page.canvasView)
    page.canvasView.becomeFirstResponder()
  }

  func setDarkMode(_ darkMode: Bool) {
    self.darkMode = darkMode
    overrideUserInterfaceStyle = darkMode ? .dark : .light
    toolPicker?.colorUserInterfaceStyle = darkMode ? .dark : .light
    toolPicker?.overrideUserInterfaceStyle = darkMode ? .dark : .light
  }

  // MARK: - Pages

  private var currentPageIndex: Int {
    guard !pages.isEmpty else { return 0 }
    let visibleCenter = scrollView.contentOffset.y + scrollView.bounds.height / 2
    var best = 0
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for (index, page) in pages.enumerated() {
      let distance = page.frame.minY > visibleCenter
        ? page.frame.minY - visibleCenter
        : max(0, visibleCenter - page.frame.maxY)
      if distance < bestDistance {
        bestDistance = distance
        best = index
      }
    }
    return best
  }

  private var currentPage: CanvasPageView? {
    return pages.isEmpty ? nil : pages[currentPageIndex]
  }

  private func makePage(_ state: CanvasPageState) throws -> CanvasPageView {
    let page = try CanvasPageView(state: state)
    page.delegate = self
    contentView.addSubview(page)
    attachToolPicker(to: page)
    return page
  }

  @MainActor
  func loadPages(json: String, initialPageId: String?) throws {
    guard let data = json.data(using: .utf8) else { throw CanvasError.invalidJson("not UTF-8") }
    let states: [CanvasPageState]
    do {
      states = try JSONDecoder().decode([CanvasPageState].self, from: data)
    } catch {
      throw CanvasError.invalidJson(error.localizedDescription)
    }

    clearSelection()
    for page in pages { page.removeFromSuperview() }
    pages = try states.map { try makePage($0) }
    if pages.isEmpty {
      let page = try makePage(CanvasPageState(id: CanvasGeometry.newId(), template: .blank, drawingDataBase64: "", textBoxes: [], images: []))
      page.dirtySinceSave = true
      pages = [page]
    }

    setNeedsLayout()
    layoutIfNeeded()

    if let initialPageId, let page = pages.first(where: { $0.pageId == initialPageId }) {
      scrollToPage(page)
    } else {
      scrollView.contentOffset = .zero
    }
    reportState()
  }

  @MainActor
  func addPage(template: PaperTemplate?) throws {
    let index = pages.isEmpty ? 0 : currentPageIndex + 1
    let template = template ?? currentPage?.template ?? .blank
    let page = try makePage(CanvasPageState(id: CanvasGeometry.newId(), template: template, drawingDataBase64: "", textBoxes: [], images: []))
    page.dirtySinceSave = true
    pages.insert(page, at: index)
    layoutPages()
    scrollToPage(page)
    pageDidChange(page)
  }

  private func scrollToPage(_ page: CanvasPageView) {
    let maxOffset = max(0, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height)
    let offset = min(maxOffset, max(0, page.frame.minY - Self.pageSpacing))
    scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    // UIKit scrolls the first responder back into view: make the target page's
    // canvas the first responder, otherwise the view jumps back.
    if window != nil {
      toolPicker?.setVisible(true, forFirstResponder: page.canvasView)
      page.canvasView.becomeFirstResponder()
    }
    // Move the accessibility focus too: otherwise UIKit scrolls back to the
    // previously focused page when the layout changes.
    UIAccessibility.post(notification: .layoutChanged, argument: page)
  }

  @MainActor
  func deleteCurrentPage() {
    guard pages.count > 1 else { return }
    let index = currentPageIndex
    let page = pages.remove(at: index)
    if selectedPage === page { clearSelection() }
    toolPicker?.removeObserver(page.canvasView)
    page.removeFromSuperview()
    layoutPages()
    onChanged([:])
    reportState()
  }

  @MainActor
  func setTemplate(_ template: PaperTemplate) {
    currentPage?.setTemplate(template)
    reportState()
  }

  // MARK: - Items

  private func visibleCenter(in page: CanvasPageView) -> CGPoint {
    let visible = scrollView.convert(scrollView.bounds, to: page).intersection(page.bounds)
    let center = visible.isNull ? CGPoint(x: page.bounds.midX, y: page.bounds.midY) : CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.3)
    return CGPoint(x: center.x / page.scale, y: center.y / page.scale)
  }

  @MainActor
  func addTextBox() {
    guard let page = currentPage else { return }
    let textBox = page.addTextBox(center: visibleCenter(in: page))
    select(textBox, on: page)
    textBox.beginEditing()
  }

  @MainActor
  func insertImage() throws {
    guard let viewController = topViewController() else { throw CanvasError.noViewController }
    pendingImagePage = currentPage

    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 1
    let picker = PHPickerViewController(configuration: configuration)
    let coordinator = ImagePickerCoordinator { [weak self] image in
      guard let self else { return }
      self.imagePicker = nil
      guard let image, let page = self.pendingImagePage ?? self.currentPage else {
        self.activateCurrentCanvas()
        return
      }
      if let view = page.addImage(image, center: self.visibleCenter(in: page)) {
        self.select(view, on: page)
      }
      self.pendingImagePage = nil
    }
    imagePicker = coordinator
    picker.delegate = coordinator
    viewController.present(picker, animated: true)
  }

  // MARK: - Selection

  private func select(_ item: CanvasItemView?, on page: CanvasPageView?) {
    if selectedItem !== item {
      if let previous = selectedItem as? CanvasTextBoxView, previous.isEditing {
        previous.endEditing()
      }
      selectedItem?.isItemSelected = false
      selectedItem = item
      selectedPage = item == nil ? nil : page
      item?.isItemSelected = true
      rebuildSelectionToolbar()
    }
    updateSelectionToolbar()
  }

  private func clearSelection() {
    select(nil, on: nil)
  }

  private func makeToolbarButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: systemImage), for: .normal)
    button.accessibilityLabel = label
    button.widthAnchor.constraint(equalToConstant: 36).isActive = true
    button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  private func rebuildSelectionToolbar() {
    for view in selectionToolbar.arrangedSubviews {
      selectionToolbar.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    selectionToolbar.removeFromSuperview()
    guard let item = selectedItem, let page = selectedPage else {
      selectionToolbar.isHidden = true
      return
    }

    if let textBox = item as? CanvasTextBoxView {
      selectionToolbar.addArrangedSubview(makeToolbarButton("textformat.size.smaller", label: "Smaller text") { [weak self] in
        textBox.setFontSize(textBox.state.fontSize - 2)
        page.markChanged()
        self?.updateSelectionToolbar()
      })
      selectionToolbar.addArrangedSubview(makeToolbarButton("textformat.size.larger", label: "Larger text") { [weak self] in
        textBox.setFontSize(textBox.state.fontSize + 2)
        page.markChanged()
        self?.updateSelectionToolbar()
      })
    }
    let delete = makeToolbarButton("trash", label: "Delete") { [weak self] in
      guard let self else { return }
      self.clearSelection()
      page.remove(item)
      self.activateCurrentCanvas()
    }
    delete.tintColor = .systemRed
    selectionToolbar.addArrangedSubview(delete)

    page.addSubview(selectionToolbar)
    selectionToolbar.isHidden = false
  }

  private func updateSelectionToolbar() {
    guard let item = selectedItem, let page = selectedPage, selectionToolbar.superview === page else { return }
    let size = selectionToolbar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    var origin = CGPoint(x: item.frame.minX, y: item.frame.minY - size.height - 8)
    if origin.y < 4 { origin.y = item.frame.maxY + 8 }
    origin.x = max(4, min(page.bounds.width - size.width - 4, origin.x))
    selectionToolbar.frame = CGRect(origin: origin, size: size)
    page.bringSubviewToFront(selectionToolbar)
  }

  // MARK: - CanvasPageViewDelegate

  func pageDidChange(_ page: CanvasPageView) {
    onChanged([:])
    reportState()
  }

  func page(_ page: CanvasPageView, didSelect item: CanvasItemView?) {
    select(item, on: page)
    if item == nil { activateCurrentCanvas() }
  }

  func page(_ page: CanvasPageView, didEndEditing textBox: CanvasTextBoxView) {
    if textBox.state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if selectedItem === textBox { clearSelection() }
      page.remove(textBox)
    }
    activateCurrentCanvas()
  }

  func pageSelectedItem() -> CanvasItemView? {
    return selectedItem
  }

  // MARK: - State reporting

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    reportState()
  }

  private func reportState() {
    let state: [String: Any] = [
      "pageCount": pages.count,
      "currentPage": currentPageIndex,
      "template": currentPage?.template.rawValue ?? PaperTemplate.blank.rawValue,
    ]
    if NSDictionary(dictionary: state).isEqual(to: lastReportedState) { return }
    lastReportedState = state
    onStateChanged(state)
  }

  // MARK: - Keyboard

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard
      let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
      let window
    else { return }
    let keyboardFrame = convert(frameValue.cgRectValue, from: window.screen.coordinateSpace)
    let overlap = max(0, bounds.maxY - keyboardFrame.minY)
    scrollView.contentInset.bottom = overlap
    scrollView.verticalScrollIndicatorInsets.bottom = overlap

    if let textBox = selectedItem as? CanvasTextBoxView, textBox.isEditing {
      scrollView.scrollRectToVisible(textBox.convert(textBox.bounds, to: scrollView).insetBy(dx: 0, dy: -40), animated: true)
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    scrollView.contentInset.bottom = 0
    scrollView.verticalScrollIndicatorInsets.bottom = 0
  }

  // MARK: - Export for saving

  // Returns JSON: all pages in order. Pages that changed since the last save (or,
  // with recognizeText, since the last recognition) include their full state,
  // a rendered PNG and optionally the recognised text.
  @MainActor
  func exportPages(recognizeText: Bool, languages: [String]) async throws -> String {
    struct PageExport: Encodable {
      var id: String
      var textContent: String
      var changed: Bool
      var state: CanvasPageState?
      var renderPngBase64: String?
      var ocrText: String?
    }

    if let textBox = selectedItem as? CanvasTextBoxView, textBox.isEditing {
      // Make sure the latest text is included
      textBox.textViewDidChange(textBox.textView)
    }

    var exports: [PageExport] = []
    var renders: [(index: Int, image: UIImage, recognize: Bool)] = []

    for page in pages {
      let needsSave = page.dirtySinceSave || (recognizeText && page.dirtySinceRecognition)
      var export = PageExport(id: page.pageId, textContent: page.textContent, changed: needsSave)
      if needsSave {
        export.state = page.makeState()
        renders.append((index: exports.count, image: page.renderImage(scale: Self.exportScale), recognize: recognizeText))
        page.dirtySinceSave = false
        if recognizeText { page.dirtySinceRecognition = false }
      }
      exports.append(export)
    }

    let encodedPages = try await Task.detached(priority: .userInitiated) { () -> [PageExport] in
      var result = exports
      for render in renders {
        guard let png = render.image.pngData() else { throw CanvasError.encodingFailed }
        result[render.index].renderPngBase64 = png.base64EncodedString()
        if render.recognize, let cgImage = render.image.cgImage {
          result[render.index].ocrText = InkTextRecognizer.recognize(cgImage, languages: languages)
        }
      }
      return result
    }.value

    let data = try JSONEncoder().encode(encodedPages)
    guard let json = String(data: data, encoding: .utf8) else { throw CanvasError.encodingFailed }
    return json
  }

  // Marks pages as unsaved again (e.g. when writing them failed in JavaScript)
  @MainActor
  func markAllUnsaved() {
    for page in pages {
      page.dirtySinceSave = true
      page.dirtySinceRecognition = true
    }
  }

  // MARK: - PDF

  @MainActor
  func sharePdf(title: String) throws {
    guard let viewController = topViewController() else { throw CanvasError.noViewController }

    let safeTitle = title
      .components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:"))
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = (safeTitle.isEmpty ? "Canvas" : safeTitle) + ".pdf"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

    let format = UIGraphicsPDFRendererFormat()
    format.documentInfo = [kCGPDFContextTitle as String: title]
    let renderer = UIGraphicsPDFRenderer(bounds: CanvasGeometry.pageRect, format: format)
    try renderer.writePDF(to: url) { context in
      for page in pages {
        context.beginPage()
        page.drawForExport(in: context.cgContext, strokesScale: 3)
      }
    }

    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = self
      popover.sourceRect = CGRect(x: bounds.maxX - 40, y: bounds.minY, width: 1, height: 1)
      popover.permittedArrowDirections = [.up]
    }
    viewController.present(activity, animated: true)
  }

  private func topViewController() -> UIViewController? {
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
      controller = presented
    }
    return controller
  }
}

// Loads the image chosen in the system photo picker
final class ImagePickerCoordinator: NSObject, PHPickerViewControllerDelegate {
  private let completion: (UIImage?) -> Void

  init(completion: @escaping (UIImage?) -> Void) {
    self.completion = completion
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    let completion = self.completion
    guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
      completion(nil)
      return
    }
    provider.loadObject(ofClass: UIImage.self) { object, _ in
      let image = object as? UIImage
      DispatchQueue.main.async { completion(image) }
    }
  }
}
