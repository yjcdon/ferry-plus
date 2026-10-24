import Foundation

/// OSS 列片页边界：分页只接受同一上传身份、递增片号和协议规定的准确片长。
struct QuarkUploadPartsPage {
    let bucket: String
    let receipts: [QuarkUploadPartReceipt]
    let isTruncated: Bool
    let nextMarker: Int

    init(data: Data, session: QuarkUploadSession, marker: Int) throws {
        guard data.count <= 1_048_576, marker >= 0, marker <= session.partCount else { throw QuarkError.invalidResponse }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw QuarkError.invalidResponse }
        let delegate = UploadPartsXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid,
              delegate.fields["Key"] == session.objectKey,
              delegate.fields["UploadId"] == session.uploadID,
              let bucket = delegate.fields["Bucket"],
              bucket.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil,
              delegate.fields["PartNumberMarker"] == String(marker),
              let limit = delegate.fields["MaxParts"].flatMap(Int.init), (1...1000).contains(limit),
              delegate.parts.count <= limit,
              let truncated = delegate.fields["IsTruncated"], ["true", "false"].contains(truncated) else {
            throw QuarkError.invalidResponse
        }
        self.bucket = bucket; isTruncated = truncated == "true"
        var previous = marker
        var receipts: [QuarkUploadPartReceipt] = []
        for part in delegate.parts {
            guard let numberText = part["PartNumber"], let number = Int(numberText), String(number) == numberText,
                  number > previous, number <= session.partCount,
                  let sizeText = part["Size"], let size = Int(sizeText), String(size) == sizeText,
                  let etag = part["ETag"] else { throw QuarkError.invalidResponse }
            let expected = Int(min(Int64(session.partSize), session.size - Int64(number - 1) * Int64(session.partSize)))
            let unquoted = etag.hasPrefix("\"") && etag.hasSuffix("\"") ? String(etag.dropFirst().dropLast()) : etag
            guard size == expected, unquoted.utf8.count == 32,
                  unquoted.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw QuarkError.invalidResponse
            }
            receipts.append(.init(uploadID: session.uploadID, number: number, size: size, etag: etag))
            previous = number
        }
        self.receipts = receipts
        if isTruncated {
            guard !receipts.isEmpty, let next = delegate.fields["NextPartNumberMarker"].flatMap(Int.init),
                  next == previous, next > marker else { throw QuarkError.invalidResponse }
            nextMarker = next
        } else {
            // 有些 OSS 网关末页仍返回最后片号；终页不依赖该值继续请求。
            nextMarker = previous
        }
    }
}

/// 只提取根字段和 Part 的直接子字段；重复字段、错误根、过深结构必须拒绝。
private final class UploadPartsXML: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    var parts: [[String: String]] = []
    var invalid = false
    private var stack: [String] = []
    private var texts: [String] = []
    private var part: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(elementName); texts.append("")
        guard stack.count <= 3, stack.count != 1 || elementName == "ListPartsResult",
              stack.count != 3 || stack[1] == "Part" else { invalid = true; parser.abortParsing(); return }
        if stack.count == 2, elementName == "Part" { part = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !texts.isEmpty { texts[texts.count - 1] += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let text = texts.popLast(), stack.last == elementName else { invalid = true; parser.abortParsing(); return }
        if stack.count == 3 {
            if part.updateValue(text, forKey: elementName) != nil { invalid = true; parser.abortParsing() }
        } else if stack.count == 2 {
            if elementName == "Part" { parts.append(part) }
            else if fields.updateValue(text, forKey: elementName) != nil { invalid = true; parser.abortParsing() }
        }
        stack.removeLast()
    }
}
