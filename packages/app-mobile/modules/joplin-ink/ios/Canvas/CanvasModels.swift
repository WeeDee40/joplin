import UIKit

// State of a canvas note page, exchanged with JavaScript as JSON.
// Coordinates and sizes are in page points (A4: 595.28 x 841.89).

enum PaperTemplate: String, Codable {
  case blank
  case lined
  case grid
}

struct CanvasTextBoxState: Codable {
  var id: String
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var text: String
  var fontSize: Double
}

struct CanvasImageState: Codable {
  var id: String
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var mime: String
  var dataBase64: String
}

struct CanvasPageState: Codable {
  var id: String
  var template: PaperTemplate
  var drawingDataBase64: String
  var textBoxes: [CanvasTextBoxState]
  var images: [CanvasImageState]
}

enum CanvasGeometry {
  // A4 in points
  static let pageSize = CGSize(width: 595.28, height: 841.89)
  static let pageRect = CGRect(origin: .zero, size: pageSize)

  static func newId() -> String {
    return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}

enum CanvasError: Error, LocalizedError {
  case invalidJson(String)
  case invalidDrawingData
  case encodingFailed
  case noViewController

  var errorDescription: String? {
    switch self {
    case .invalidJson(let reason): return "Invalid canvas data: \(reason)"
    case .invalidDrawingData: return "The PencilKit drawing data could not be decoded."
    case .encodingFailed: return "The page could not be rendered."
    case .noViewController: return "No view controller to present from."
    }
  }
}
