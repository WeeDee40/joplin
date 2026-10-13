import ExpoModulesCore

struct CanvasExportOptions: Record {
  @Field var recognizeText: Bool = false
  @Field var recognitionLanguages: [String] = ["de-CH", "de-DE", "en-US"]
}

public class JoplinCanvasModule: Module {
  public func definition() -> ModuleDefinition {
    Name("JoplinCanvas")

    View(JoplinCanvasView.self) {
      Events("onReady", "onChanged", "onStateChanged")

      Prop("darkMode") { (view: JoplinCanvasView, darkMode: Bool?) in
        view.setDarkMode(darkMode ?? false)
      }

      AsyncFunction("loadPages") { (view: JoplinCanvasView, pagesJson: String, initialPageId: String?) async throws in
        try await view.loadPages(json: pagesJson, initialPageId: initialPageId)
      }

      AsyncFunction("exportPages") { (view: JoplinCanvasView, options: CanvasExportOptions) async throws -> String in
        return try await view.exportPages(recognizeText: options.recognizeText, languages: options.recognitionLanguages)
      }

      AsyncFunction("markAllUnsaved") { (view: JoplinCanvasView) async in
        await view.markAllUnsaved()
      }

      AsyncFunction("addPage") { (view: JoplinCanvasView, template: String?) async throws in
        try await view.addPage(template: template.flatMap { PaperTemplate(rawValue: $0) })
      }

      AsyncFunction("deleteCurrentPage") { (view: JoplinCanvasView) async in
        await view.deleteCurrentPage()
      }

      AsyncFunction("setTemplate") { (view: JoplinCanvasView, template: String) async in
        if let value = PaperTemplate(rawValue: template) {
          await view.setTemplate(value)
        }
      }

      AsyncFunction("addTextBox") { (view: JoplinCanvasView) async in
        await view.addTextBox()
      }

      AsyncFunction("insertImage") { (view: JoplinCanvasView) async throws in
        try await view.insertImage()
      }

      AsyncFunction("sharePdf") { (view: JoplinCanvasView, title: String) async throws in
        try await view.sharePdf(title: title)
      }

      AsyncFunction("showToolPicker") { (view: JoplinCanvasView) async in
        await view.activateCurrentCanvas()
      }
    }
  }
}
