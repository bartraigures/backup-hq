import Foundation

/// Tiny DOM built on Foundation's XMLParser, enough for S3's flat response documents.
final class S3XMLNode {
    let name: String
    var text: String = ""
    var children: [S3XMLNode] = []
    weak var parent: S3XMLNode?

    init(name: String, parent: S3XMLNode?) {
        self.name = name
        self.parent = parent
    }

    /// First direct child with `name`.
    subscript(_ name: String) -> S3XMLNode? { children.first { $0.name == name } }
    /// All direct children with `name`.
    func all(_ name: String) -> [S3XMLNode] { children.filter { $0.name == name } }
    /// Trimmed text of the first direct child, if any.
    func string(_ name: String) -> String? {
        guard let node = self[name] else { return nil }
        let t = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty && !node.children.isEmpty ? nil : t
    }

    /// Parses `data` and returns the root element, or nil if the document is not XML.
    static func parse(_ data: Data) -> S3XMLNode? {
        guard !data.isEmpty else { return nil }
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: S3XMLNode?
        var current: S3XMLNode?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let node = S3XMLNode(name: elementName, parent: current)
            if let current { current.children.append(node) } else { root = node }
            current = node
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { current?.text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { current = current?.parent }
    }
}

/// Escapes text for inclusion in an XML body.
func s3XMLEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(ch)
        }
    }
    return out
}
