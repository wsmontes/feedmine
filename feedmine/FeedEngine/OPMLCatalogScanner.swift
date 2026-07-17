import Foundation

struct OPMLCatalogScanner: Sendable {
    let rootURL: URL

    func scan() throws -> [CatalogSourceOccurrence] {
        let files = try opmlFiles()
        return try files.enumerated().flatMap { fileIndex, fileURL in
            let relativePath = Self.relativePath(for: fileURL, rootURL: rootURL)
            let fileData = try Data(contentsOf: fileURL)
            let fileLanguage = Self.extractLanguage(from: fileData)
            let folderNodes = Self.folderNodes(for: relativePath, fileName: fileURL.deletingPathExtension().lastPathComponent)
            let mediaKind = OPMLParser.mediaKind(for: fileURL.deletingPathExtension().lastPathComponent)
            let parser = XMLParser(data: fileData)
            let delegate = CatalogOPMLDelegate(
                folderNodes: folderNodes,
                fallbackCategory: fileURL.deletingPathExtension().lastPathComponent.capitalized,
                opmlFile: relativePath,
                fileIndex: fileIndex,
                fileLanguage: fileLanguage,
                defaultMediaKind: mediaKind
            )
            parser.delegate = delegate
            parser.parse()
            if let error = parser.parserError {
                throw error
            }
            return delegate.occurrences
        }
    }

    private func opmlFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "opml" {
            files.append(fileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return fileURL.lastPathComponent
    }

    static func folderNodes(for relativePath: String, fileName: String) -> [CatalogInputNode] {
        let directoryParts = relativePath
            .split(separator: "/")
            .dropLast()
            .map(String.init)

        if directoryParts.first == "countries" {
            var nodes = [CatalogInputNode(name: "Countries", kind: .topic, keyComponent: "countries")]
            let countryParts = Array(directoryParts.dropFirst())
            for (index, part) in countryParts.enumerated() {
                nodes.append(CatalogInputNode(
                    name: displayName(fromSlug: part),
                    kind: index == 0 ? .country : .region,
                    keyComponent: part
                ))
            }
            if let country = countryParts.first {
                appendCountryFileNode(fileName: fileName, country: country, to: &nodes)
            }
            return nodes
        }

        if directoryParts.first == "languages", directoryParts.count >= 2 {
            var nodes = [CatalogInputNode(name: "Languages", kind: .topic, keyComponent: "languages")]
            for (index, part) in directoryParts.dropFirst().enumerated() {
                nodes.append(CatalogInputNode(
                    name: displayName(fromSlug: part),
                    kind: index == 0 ? .language : .subcategory,
                    keyComponent: part
                ))
            }
            appendFileNodeIfNeeded(fileName: fileName, kind: .subcategory, to: &nodes)
            return nodes
        }

        if !directoryParts.isEmpty {
            var nodes = directoryParts.enumerated().map { index, part in
                CatalogInputNode(
                    name: displayName(fromSlug: part),
                    kind: index == 0 ? .topic : .subcategory,
                    keyComponent: CatalogIdentity.slug(part)
                )
            }
            appendFileNodeIfNeeded(fileName: fileName, kind: .subcategory, to: &nodes)
            return nodes
        }

        return [
            CatalogInputNode(name: "Global", kind: .topic, keyComponent: "global"),
            CatalogInputNode(name: displayName(fromSlug: fileName), kind: .subcategory, keyComponent: CatalogIdentity.slug(fileName)),
        ]
    }

    static func extractLanguage(from data: Data) -> String? {
        let head = String(data: data.prefix(2048), encoding: .utf8) ?? ""
        guard let range = head.range(of: "<language>"),
              let endRange = head.range(of: "</language>", range: range.upperBound..<head.endIndex) else {
            return nil
        }
        let lang = String(head[range.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lang.isEmpty ? nil : lang
    }

    private static func displayName(fromSlug slug: String) -> String {
        slug
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func appendCountryFileNode(
        fileName: String,
        country: String,
        to nodes: inout [CatalogInputNode]
    ) {
        let key: String
        if fileName == country {
            return
        } else if fileName.hasPrefix("\(country)-") {
            key = String(fileName.dropFirst(country.count + 1))
        } else {
            key = CatalogIdentity.slug(fileName)
        }
        appendFileNodeIfNeeded(fileName: key, kind: .region, to: &nodes)
    }

    private static func appendFileNodeIfNeeded(
        fileName: String,
        kind: CatalogNodeKind,
        to nodes: inout [CatalogInputNode]
    ) {
        let key = CatalogIdentity.slug(fileName)
        guard nodes.last?.keyComponent != key else { return }
        nodes.append(CatalogInputNode(name: displayName(fromSlug: fileName), kind: kind, keyComponent: key))
    }
}

private final class CatalogOPMLDelegate: NSObject, XMLParserDelegate {
    private let folderNodes: [CatalogInputNode]
    private let fallbackCategory: String
    private let opmlFile: String
    private let fileIndex: Int
    private let fileLanguage: String?
    private let defaultMediaKind: MediaKind

    private var outlineStack: [(name: String, language: String?)] = []
    private var outlinePushStack: [Bool] = []
    private var order = 0

    var occurrences: [CatalogSourceOccurrence] = []

    init(
        folderNodes: [CatalogInputNode],
        fallbackCategory: String,
        opmlFile: String,
        fileIndex: Int,
        fileLanguage: String?,
        defaultMediaKind: MediaKind
    ) {
        self.folderNodes = folderNodes
        self.fallbackCategory = fallbackCategory
        self.opmlFile = opmlFile
        self.fileIndex = fileIndex
        self.fileLanguage = fileLanguage
        self.defaultMediaKind = defaultMediaKind
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "outline" else { return }
        let xmlURL = attributeDict["xmlUrl"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = attributeDict["title"] ?? attributeDict["text"] ?? fallbackCategory
        let language = attributeDict["language"] ?? outlineStack.last?.language ?? fileLanguage

        guard !xmlURL.isEmpty else {
            if !name.isEmpty {
                outlineStack.append((name, language))
                outlinePushStack.append(true)
            } else {
                outlinePushStack.append(false)
            }
            return
        }

        outlinePushStack.append(false)
        guard let components = URLComponents(string: xmlURL),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host != nil else {
            return
        }

        let categoryNodes = outlineStack.map {
            CatalogInputNode(
                name: $0.name,
                kind: .subcategory,
                language: $0.language
            )
        }
        let nodePath = (folderNodes + categoryNodes).isEmpty
            ? [CatalogInputNode(name: fallbackCategory, kind: .topic)]
            : folderNodes + categoryNodes
        let title = name.isEmpty ? (outlineStack.last?.name ?? fallbackCategory) : name
        let mediaKind = Self.mediaKind(xmlURL: xmlURL, defaultMediaKind: defaultMediaKind)

        occurrences.append(CatalogSourceOccurrence(
            title: title,
            declaredURL: xmlURL,
            mediaKind: mediaKind,
            language: language,
            nodePath: nodePath,
            opmlFile: opmlFile,
            sortOrder: fileIndex * 1_000_000 + order,
            titleOverride: title,
            languageOverride: language,
            mediaKindOverride: mediaKind
        ))
        order += 1
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "outline" else { return }
        let didPush = outlinePushStack.popLast() ?? false
        if didPush, !outlineStack.isEmpty {
            outlineStack.removeLast()
        }
    }

    private static func mediaKind(xmlURL: String, defaultMediaKind: MediaKind) -> MediaKind {
        if xmlURL.contains("youtube.com/feeds") { return .video }
        if xmlURL.contains("anchor.fm") || xmlURL.contains("spreaker.com") || xmlURL.contains("podcast") { return .audio }
        if xmlURL.contains("reddit.com/r/") { return .forum }
        return defaultMediaKind
    }
}
