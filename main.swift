import Foundation


let DATA_SOURCE = "https://data.source.coop/protomaps/openstreetmap/tiles/v3.pmtiles"

// func lon2tile(lon, zoom) {return (lon+180)/360*Math.pow(2,zoom); }
// func lat2tile(lat, zoom) { return (1-Math.log(Math.tan(lat*Math.PI/180) + 1/Math.cos(lat*Math.PI/180))/Math.PI)/2 *Math.pow(2,zoom); }

@main
struct App {
    static func main() async throws {
        let buildings = try await fetchBuildings()
        print("found \(buildings.count) buildings on this tile!")

        let buildingSvg = buildingToSvg(building: buildings[0])
        try buildingSvg.write(
            to: URL(fileURLWithPath: "test.svg"),
            atomically: true,
            encoding: .utf8
        )
        print("made test.svg")
    }

    static func buildingToSvg(building b: Layer.Feature) -> String {
        var out = """
        <?xml version="1.0" standalone="no"?>
        <svg
            xmlns="http://www.w3.org/2000/svg"
            version="1.1"
            viewBox="\(b.bbox.min_x) \(b.bbox.min_y)
                    \(b.bbox.max_x - b.bbox.min_x) \(b.bbox.max_y - b.bbox.min_y)"
        >
        """

        out += "<path d=\""
        for geometry in b.geometries {
            for line in geometry.lines {
                for (index, point) in line.enumerated() {
                    if index == 0 {
                        out += "M "
                    } else {
                        out += "L "
                    }
                    out += String(point.x)
                    out += " "
                    out += String(point.y)
                    out += " "
                }
                out += "Z "
            }
        }
        out += "\"/>"

        out += "</svg>"
        return out
    }

    enum E: Error {
        case NoBuildings
    }

    static func fetchBuildings() async throws -> [Layer.Feature] {
        var req = URLRequest(url: URL(string: DATA_SOURCE)!)
        req.addValue("bytes=73588031848-73588053431", forHTTPHeaderField: "Range")
        req.addValue("application/octet-stream", forHTTPHeaderField: "Accept")

        var (data, _) = try await URLSession.shared.data(for: req)

        /* skip header & decompress */
        data = try! (data[10...] as NSData).decompressed(using: .zlib) as Data

        var bds = BinaryDataStream(data: data)

        while bds.i != bds.data.count {
            let layer = try bds.readLayer()
            if layer.name == "buildings" {
                return layer.features
            }
        }
        throw E.NoBuildings
    }
}

struct BinaryDataStream {
    var data: Data
    var i = 0

    enum E: Error {
        case VarintTooBig
        case InvalidString
        case UnknownType
    }

    mutating func readByte() -> UInt8 {
        let b = data[i]
        i += 1
        return b
    }

    mutating func readVarint() throws -> Int {
        var val = 0;
        var b = readByte()
        val = Int(b) & 0x7f
        if b < 0x80 { return val }

        b = readByte()
        val |= (Int(b) & 0x7f) << 7
        if b < 0x80 { return val }

        b = readByte()
        val |= (Int(b) & 0x7f) << 14
        if b < 0x80 { return val }

        b = readByte()
        val |= (Int(b) & 0x7f) << 21
        if b < 0x80 { return val }

        b = readByte()
        val |= (Int(b) & 0x7f) << 28
        if b < 0x80 { return val }

        throw E.VarintTooBig
    }

    mutating func readSVarint() throws -> Int {
        let num = try readVarint()
        if (num % 2) == 1 {
            return (num + 1) / -2
        } else {
            return num / 2
        }
    }

    mutating func readString() throws -> String {
        let strlen = try readVarint()
        let start = i
        let end = i + strlen
        i = end;
        guard let str = String(bytes: data[start..<end], encoding: .utf8)
            else { throw E.InvalidString }
        return str
    }

    mutating func skipField(type: Int) throws {
        enum PBF: Int {
            case Varint = 0
            case Bytes = 2
            case Fixed32 = 5
            case Fixed64 = 1
        }

        guard let pbf = PBF(rawValue: type & 0b111) else { throw E.UnknownType }
        switch pbf {
            case PBF.Varint:
                while (data[i] > 0x7f) { i += 1 } 
                i += 1
            case PBF.Bytes:
                i = try readVarint() + i;
            case PBF.Fixed32:
                i += 4
            case PBF.Fixed64:
                i += 8
        }
    }

    mutating func readGeometry() throws -> Layer.Feature.Geometry {
        let end = try readVarint() + i

        var lines: [[(x: Int, y: Int)]] = []
        var line: [(x: Int, y: Int)] = []

        var cmd = 1
        var length = 0

        var x = 0
        var y = 0

        while i < end {
            if length <= 0 {
                let cmdAndLen = try readVarint()
                cmd = cmdAndLen & 0b111
                length = cmdAndLen >> 3
            }
            length -= 1

            /* new line (1) or continuation of line (2) */
            if cmd == 1 || cmd == 2 {
                x += try readSVarint()
                y += try readSVarint()

                if cmd == 1 {
                    if line.count > 0 {
                        lines.append(line)
                    }
                    line = []
                }

                line.append((x: x, y: y ))

                continue
            }

            /* cmd 7 is a single point - seems to only be used for POIs */
        }

        if line.count > 0 {
            lines.append(line)
        }

        return Layer.Feature.Geometry(lines: lines)
    }

    mutating func readLayer() throws -> Layer {
        _ = try readVarint() /* layer field tag */
        let layerEnd = (try readVarint()) + i

        var features: [Layer.Feature] = []
        var name = ""

        while i != layerEnd {
            let featureKind = try readVarint()

            switch (featureKind >> 3) {
                case 1:
                    name = try readString()
                case 2:
                    var geometries: [Layer.Feature.Geometry] = []

                    let end = try readVarint() + i
                    while i < end {
                        let featureType = try readVarint()
                        let featureTag = featureType >> 3
                        if featureTag == 4 {
                            geometries.append(try readGeometry())
                        } else {
                            try skipField(type: featureType)
                        }
                    }

                    features.append(Layer.Feature(geometries: geometries))
                default:
                    try skipField(type: featureKind)
            }
        }

        i = layerEnd
        return Layer(name: name, features: features)
    }
}

struct Layer {
    struct Feature {
        struct Geometry {
            let lines: [[(x: Int, y: Int)]]
        }
        let bbox: (min_x: Int, min_y: Int, max_x: Int, max_y: Int)
        let geometries: [Geometry]

        init(geometries: [Geometry]) {
            var min_x = Int( 1e6)
            var min_y = Int( 1e6)
            var max_x = Int(-1e6)
            var max_y = Int(-1e6)

            for g in geometries {
                for line in g.lines {
                    for point in line {
                        min_x = min(min_x, point.x)
                        min_y = min(min_y, point.y)
                        max_x = max(max_x, point.x)
                        max_y = max(max_y, point.y)
                    }
                }
            }
            self.bbox = (min_x, min_y, max_x, max_y)
            self.geometries = geometries
        }
    }

    let name: String
    let features: [Feature]
}


// bytes=0-16384
// parse header
// print(data.withUnsafeBytes { d in
//     func unalignedInt32(offset: Int) -> Int32 {
//         var tmp: Int32 = 0;
//         memcpy(&tmp, d.baseAddress!.advanced(by: offset), MemoryLayout<Int32>.size);
//         return Int32(littleEndian: tmp)
//     }

//     return (
//         specVersion         : d.load(fromByteOffset: 7  , as: UInt8 .self),
//         rootDirectoryOffset : d.load(fromByteOffset: 8  , as: UInt64.self),
//         rootDirectoryLength : d.load(fromByteOffset: 16 , as: UInt64.self),
//         jsonMetadataOffset  : d.load(fromByteOffset: 24 , as: UInt64.self),
//         jsonMetadataLength  : d.load(fromByteOffset: 32 , as: UInt64.self),
//         leafDirectoryOffset : d.load(fromByteOffset: 40 , as: UInt64.self),
//         leafDirectoryLength : d.load(fromByteOffset: 48 , as: UInt64.self),
//         tileDataOffset      : d.load(fromByteOffset: 56 , as: UInt64.self),
//         tileDataLength      : d.load(fromByteOffset: 64 , as: UInt64.self),
//         numAddressedTiles   : d.load(fromByteOffset: 72 , as: UInt64.self),
//         numTileEntries      : d.load(fromByteOffset: 80 , as: UInt64.self),
//         numTileContents     : d.load(fromByteOffset: 88 , as: UInt64.self),
//         clustered           : d.load(fromByteOffset: 96 , as: UInt8 .self) == 1,
//         internalCompression : d.load(fromByteOffset: 97 , as: UInt8 .self),
//         tileCompression     : d.load(fromByteOffset: 98 , as: UInt8 .self),
//         tileType            : d.load(fromByteOffset: 99 , as: UInt8 .self),
//         minZoom             : d.load(fromByteOffset: 100, as: UInt8 .self),
//         maxZoom             : d.load(fromByteOffset: 101, as: UInt8 .self),
//         minLon              : unalignedInt32(offset: 102) / 10000000,
//         minLat              : unalignedInt32(offset: 106) / 10000000,
//         maxLon              : unalignedInt32(offset: 110) / 10000000,
//         maxLat              : unalignedInt32(offset: 114) / 10000000,
//         centerZoom          : unalignedInt32(offset: 118),
//         centerLon           : unalignedInt32(offset: 119) / 10000000,
//         centerLat           : unalignedInt32(offset: 123) / 10000000,
//     );
// })
