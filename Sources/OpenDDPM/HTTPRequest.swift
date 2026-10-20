import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    static func parse(_ data: Data) throws -> Self? {
        guard data.count <= 16_384 else { throw ControlError.message("Request too large.") }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let start = (lines.first ?? "").split(separator: " ")
        guard start.count == 3, start[2] == "HTTP/1.1", start[1].hasPrefix("/") else { throw ControlError.message("Invalid HTTP request.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { throw ControlError.message("Invalid header.") }
            let name = pair[0].lowercased()
            guard headers[name] == nil else { throw ControlError.message("Duplicate header.") }
            headers[name] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), (0...8192).contains(length) else { throw ControlError.message("Invalid body length.") }
        let body = Data(data[separator.upperBound...])
        guard body.count >= length else { return nil }
        guard body.count == length else { throw ControlError.message("Only one request per connection is supported.") }
        return Self(method: String(start[0]), path: String(start[1]), headers: headers, body: body)
    }
}
