import ExpoModulesCore

struct LoadDrawingOptions: Record {
  // PKDrawing.dataRepresentation(), base64-encoded
  @Field var drawingDataBase64: String?
  @Field var canvasWidth: Double = 768

  // An already-rasterised background layer (from a previous save)
  @Field var backgroundPngBase64: String?
  @Field var backgroundX: Double = 0
  @Field var backgroundY: Double = 0
  @Field var backgroundWidth: Double = 0
  @Field var backgroundHeight: Double = 0

  // A legacy (non-PencilKit) SVG that should be rasterised and shown as the
  // background layer. Placed at (0, 0) with the size given above.
  @Field var legacySvg: String?
}

struct ExportDrawingOptions: Record {
  @Field var recognizeText: Bool = false
  @Field var recognitionLanguages: [String] = ["de-CH", "de-DE", "en-US"]
}

public class JoplinInkModule: Module {
  public func definition() -> ModuleDefinition {
    Name("JoplinInk")

    View(JoplinInkView.self) {
      Events("onDrawingChanged")

      Prop("darkMode") { (view: JoplinInkView, darkMode: Bool?) in
        view.setDarkMode(darkMode ?? false)
      }

      Prop("paperColor") { (view: JoplinInkView, color: UIColor?) in
        view.backgroundColor = color ?? .white
      }

      AsyncFunction("loadDrawing") { (view: JoplinInkView, options: LoadDrawingOptions) async throws -> [String: Any] in
        return try await view.loadDrawing(options)
      }

      AsyncFunction("exportDrawing") { (view: JoplinInkView, options: ExportDrawingOptions) async throws -> [String: Any] in
        return try await view.exportDrawing(options)
      }

      AsyncFunction("showToolPicker") { (view: JoplinInkView) async in
        await view.showToolPicker()
      }
    }
  }
}
