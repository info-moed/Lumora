// Prints the text macOS reads in each image (Vision OCR). Used by scripts/screenshots.sh to make sure no published
// screenshot shows the account name, a home-folder path or a private email.

import Vision
import AppKit
let args = CommandLine.arguments.dropFirst()
for path in args {
    guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    print("=== \((path as NSString).lastPathComponent)\n\(text)")
}
