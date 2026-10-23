#if canImport(zlib)
import zlib
#else
import CZlib
#endif

enum Deflate {
    static func compress(_ input: [UInt8]) throws(LayoutError) -> [UInt8] {
        var stream = z_stream()
        let initialized = deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY,
                                        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw LayoutError("compression failed with zlib status \(initialized)") }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))))
        let status = run(&stream, input: input, output: &output) { deflate(&$0, Z_FINISH) }
        guard status == Z_STREAM_END else { throw LayoutError("compression failed with zlib status \(status)") }
        return Array(output.prefix(Int(stream.total_out)))
    }

    static func decompress(_ input: [UInt8], limit: Int) -> [UInt8]? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: limit + 1)
        let status = run(&stream, input: input, output: &output) { inflate(&$0, Z_FINISH) }
        guard status == Z_STREAM_END, stream.avail_in == 0, Int(stream.total_out) <= limit else { return nil }
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
}
