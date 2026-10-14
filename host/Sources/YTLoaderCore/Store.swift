import Foundation

/// Один испорченный элемент не должен убивать всю очередь или историю.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = try? c.decode(T.self)
    }
}

public enum Store {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func loadArray<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Lossy<T>].self, from: data) else { return [] }
        return list.compactMap { $0.value }
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.shared.write("save failed \(url.lastPathComponent): \(error)")
        }
    }
}
