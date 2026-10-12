import Vision

// On-device handwriting recognition with Apple Vision. The result is stored in
// the resource's `ocr_text` so that drawings can be found with the Joplin search.
enum InkTextRecognizer {
  static func recognize(_ image: CGImage, languages: [String]) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    // Not every language is available for every revision (e.g. "de-CH" may
    // not be). Use the supported ones, in the requested order of preference.
    if let supported = try? request.supportedRecognitionLanguages() {
      let available = languages.filter { supported.contains($0) }
      if !available.isEmpty {
        request.recognitionLanguages = available
      }
    }

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      NSLog("JoplinInk: text recognition failed: \(error)")
      return ""
    }

    let observations = request.results ?? []
    // Sort top-to-bottom, then left-to-right (Vision uses a bottom-left origin)
    let sorted = observations.sorted { a, b in
      let dy = a.boundingBox.midY - b.boundingBox.midY
      if abs(dy) > min(a.boundingBox.height, b.boundingBox.height) / 2 {
        return dy > 0
      }
      return a.boundingBox.minX < b.boundingBox.minX
    }

    return sorted
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}
