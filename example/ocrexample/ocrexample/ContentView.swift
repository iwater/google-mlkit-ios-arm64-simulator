import SwiftUI
import MLKitTextRecognition
import MLKitCommon
import MLKitVision
import MLKitTextRecognitionCommon
import MLImage

struct ContentView: View {
    @State private var recognizedText: String = ""
    @State private var isProcessing = false
    @State private var status = "点击按钮测试 OCR"

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "text.magnifyingglass")
                    .imageScale(.large)
                    .font(.system(size: 64))
                    .foregroundColor(.blue)

                Text("Google ML Kit OCR 测试")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: testOCR) {
                    Label("测试本地图片 OCR", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                if isProcessing {
                    ProgressView("正在识别...")
                }

                if !recognizedText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("识别结果")
                                .font(.headline)
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = recognizedText
                            }) {
                                Label("复制", systemImage: "doc.on.doc")
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
        status = "正在初始化识别器..."

        let textRecognizer = TextRecognizer.textRecognizer()

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 32),
                .foregroundColor: UIColor.black
            ]
            "Hello World!\nML Kit OCR 测试\nGoogle 文字识别"
                .draw(at: CGPoint(x: 20, y: 30), withAttributes: attrs)
        }

        guard let mlImage = MLImage(image: image) else {
            isProcessing = false
            status = "无法创建 MLImage"
            return
        }

        status = "正在识别文字..."

        textRecognizer.process(mlImage) { result, error in
            isProcessing = false
            if let error = error {
                status = "识别失败"
                recognizedText = "错误: \(error.localizedDescription)"
                return
            }
            if let result = result {
                status = "识别完成"
                recognizedText = result.text
            }
        }
    }
}

#Preview {
    ContentView()
}
