import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 文件选择

/// 系统文件选择器。以副本方式打开（asCopy），选中的文件先拷进 App 的临时目录，
/// 不用处理安全访问权限，iCloud、其他 App 的文件夹里的文件都能读到。
/// 类型放宽到任意文件：很多音源 / 书源文件扩展名不规范（.txt、没有扩展名），按类型过滤会选不了
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.item]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

extension View {
    /// 弹出文件选择器，选中后回调文件内容和文件名
    func filePicker(isPresented: Binding<Bool>, types: [UTType] = [.item], onPick: @escaping (Data, String) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DocumentPicker(types: types) { url in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                onPick(data, url.lastPathComponent)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - 相册选图

/// 系统相册选择器（PHPicker，不需要相册权限）
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage) -> Void

        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            let onPick = onPick
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { onPick(image) }
            }
        }
    }
}

// MARK: - 文本解码

enum TextDecoding {
    /// 文件内容转文字：去掉 BOM，UTF-8 / UTF-16 / GB18030 依次尝试（Windows 上保存的书源常见 BOM 和 GBK）
    static func string(from data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
