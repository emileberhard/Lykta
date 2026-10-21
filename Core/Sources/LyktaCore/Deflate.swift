#if canImport(zlib)
import zlib
#else
import CZlib
#endif

enum Deflate {
    enum Failure: Error {
        case zlib(Int32)
        case malformed
        case exceedsLimit
    }

    static func compress(_ input: [UInt8]) throws(Failure) -> [UInt8] {
        var stream = z_stream()
        try check(deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)))
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))))
        let status = run(&stream, input: input, output: &output) { deflate(&$0, Z_FINISH) }
        guard status == Z_STREAM_END else { throw .zlib(status) }
        return Array(output.prefix(Int(stream.total_out)))
    }

    static func decompress(_ input: [UInt8], limit: Int) throws(Failure) -> [UInt8] {
        var stream = z_stream()
        try check(inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)))
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: limit + 1)
        let status = run(&stream, input: input, output: &output) { inflate(&$0, Z_FINISH) }
        guard Int(stream.total_out) <= limit else { throw .exceedsLimit }
        guard status == Z_STREAM_END, stream.avail_in == 0 else { throw .malformed }
        return Array(output.prefix(Int(stream.total_out)))
    }

    private static func run(_ stream: inout z_stream, input: [UInt8], output: inout [UInt8],
                            step: (inout z_stream) -> Int32) -> Int32 {
        var source = input
        return source.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress
                stream.avail_in = uInt(source.count)
                stream.next_out = target.baseAddress
                stream.avail_out = uInt(target.count)
                return step(&stream)
            }
        }
    }

    private static func check(_ status: Int32) throws(Failure) {
        guard status == Z_OK else { throw .zlib(status) }
    }
}
