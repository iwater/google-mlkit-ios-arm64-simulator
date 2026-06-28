import SwiftUI
import MLKitTextRecognition
import MLKitCommon
import MLKitVision
import MLKitTextRecognitionCommon
import MLImage

struct ContentView: View {
    @State private var recognizedText: String = ""
    @State private var isProcessing = false
    @State private var status = "Tap the button to test OCR"

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "text.magnifyingglass")
                    .imageScale(.large)
                    .font(.system(size: 64))
                    .foregroundColor(.blue)

                Text("Google ML Kit OCR Test")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: testOCR) {
                    Label("Test OCR on local image", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                if isProcessing {
                    ProgressView("Recognizing...")
                }

                if !recognizedText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recognition Result")
                                .font(.headline)
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = recognizedText
                            }) {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                        }
                        ScrollView {
                            Text(recognizedText)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 300)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("ML Kit OCR")
            .padding(.top)
        }
    }

    func testOCR() {
        isProcessing = true
        recognizedText = ""
        status = "Initializing recognizer..."

        let textRecognizer = TextRecognizer.textRecognizer()

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 32),
                .foregroundColor: UIColor.black
            ]
            "Hello World!\nML Kit OCR Test\nGoogle Text Recognition"
                .draw(at: CGPoint(x: 20, y: 30), withAttributes: attrs)
        }

        guard let mlImage = MLImage(image: image) else {
            isProcessing = false
            status = "Failed to create MLImage"
            return
        }

        status = "Processing image..."

        textRecognizer.process(mlImage) { result, error in
            isProcessing = false
            if let error = error {
                status = "Recognition failed"
                recognizedText = "Error: \(error.localizedDescription)"
                return
            }
            if let result = result {
                status = "Recognition completed"
                recognizedText = result.text
            }
        }
    }
}

#Preview {
    ContentView()
}
