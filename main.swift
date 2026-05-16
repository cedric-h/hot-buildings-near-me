import Foundation

@main
struct App {
    static func main() async throws {
        var args = CommandLine.arguments
        if args.count < 2 { args.append("40.759488926995914",) }
        if args.count < 3 { args.append("-111.88670140830416") }
        let lat = Double((args[1]).trimmingCharacters(in: CharacterSet(charactersIn: ",")))!
        let lon = Double((args[2]).trimmingCharacters(in: CharacterSet(charactersIn: ",")))!

        print("looking for buildings on \((lat: lat, lon: lon))")
        let buildings = try await Map.fetchBuildings(lat: lat, lon: lon)

        if buildings.count == 0 {
            print("no buildings found!")
            return
        }

        print("found \(buildings.count) buildings on this tile!")

        let buildingSvg = buildingToSvg(building: buildings[0])
        try buildingSvg.write(
            to: URL(fileURLWithPath: "test.svg"),
            atomically: true,
            encoding: .utf8
        )
        print(#"put the closest building in "test.svg""#)
    }
}

func buildingToSvg(building b: Layer.Feature) -> String {
    var out = """
    <?xml version="1.0" standalone="no"?>
    <svg
        xmlns="http://www.w3.org/2000/svg"
        version="1.1"
        viewBox="\(b.bbox.min_x - 10) \(b.bbox.min_y - 10)
                \(b.bbox.max_x - b.bbox.min_x + 20) \(b.bbox.max_y - b.bbox.min_y + 20)"
    >
    """

    out += "<path stroke=\"black\" stroke-width=\"5\" fill=\"#eaac3b\" d=\""
    /* in practice it seems there is only ever one geometry in this dataset */
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

class Map {
    static let DATA_SOURCE = "https://data.source.coop/protomaps/openstreetmap/tiles/v3.pmtiles"
    static let GZIP_HEADER_SIZE: UInt64 = 10

    static func fetchMapBytes(from: UInt64, to: UInt64) async throws -> Data {
        var req = URLRequest(url: URL(string: DATA_SOURCE)!)
        req.addValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        req.addValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    typealias FractionalTileCoord = (tileId: UInt64, xFrac: Double, yFrac: Double)
    static func latLonToTileId(lat: Double, lon: Double, zoom: Double) -> FractionalTileCoord {
        func lat2tile(lat: Double, zoom: Double) -> Double {
            let x = tan(lat * Double.pi / 180) + 1/cos(lat * Double.pi/180)
            return (1 - log(x) / Double.pi)/2 * pow(2, zoom)
        }
        func lon2tile(lon: Double, zoom: Double) -> Double {
            return (lon + 180) / 360 * pow(2, zoom)
        }

        var x: UInt64 = UInt64(lon2tile(lon: lon, zoom: zoom))
        var y: UInt64 = UInt64(lat2tile(lat: lat, zoom: zoom))
        let acc: UInt64 = [
            0, 1, 5, 21, 85, 341, 1365, 5461, 21845, 87381, 349525,
            1398101, 5592405, 22369621, 89478485, 357913941, 1431655765
        ][Int(zoom)];
        let n: UInt64 = UInt64(pow(2, Double(zoom)))
        var rx: UInt64 = 0
        var ry: UInt64 = 0
        var d: UInt64 = 0
        var s: UInt64 = n / 2;
        while s > 0 {
            rx = ((x & s) > 0) ? 1 : 0
            ry = ((y & s) > 0) ? 1 : 0
            d += s * s * (3 * rx ^ ry)
            do {
                if ry == 0 {
                    if rx == 1 {
                        x = n - 1 - x
                        y = n - 1 - y
                    }
                    (x, y) = (y, x)
                }
            }
            s = s / 2
        }
        return FractionalTileCoord(
            tileId: UInt64(acc + d),
            xFrac: lon2tile(lon: lon, zoom: zoom) - floor(lon2tile(lon: lon, zoom: zoom)),
            yFrac: lat2tile(lat: lat, zoom: zoom) - floor(lat2tile(lat: lat, zoom: zoom)),
        )
    }

    typealias Entry = (tileId: UInt64, offset: UInt64, length: UInt64, runLength: UInt64)

    static func sortBuildingsByCloseness(
        _ buildings: [Layer.Feature], 
        x xFrac: Double,
        y yFrac: Double,
    ) -> [Layer.Feature] {
        let x = Int(xFrac * 4200)
        let y = Int(yFrac * 4200)

        func scoreBuildingProximity(_ b: Layer.Feature) -> Double {
            var score = Double(0)

            if x > b.bbox.min_x && x < b.bbox.max_x &&
               y > b.bbox.min_y && y < b.bbox.max_y {
               score -= 1000
           }

           var closest = Double(1e6)
           for (cx, cy) in [
               (b.bbox.min_x, b.bbox.min_y),
               (b.bbox.min_x, b.bbox.max_y),
               (b.bbox.max_x, b.bbox.min_y),
               (b.bbox.max_x, b.bbox.max_y),
           ] {
               let fx = Double((cx - x)*(cx - x))
               let fy = Double((cy - y)*(cy - y))
               let dist = sqrt(fx*fx + fy*fy)
               closest = min(closest, dist)
           }
           score += closest

           return score
        }

        return buildings.sorted(by: { a, b in 
            return scoreBuildingProximity(a) < scoreBuildingProximity(b)
        })
    }

    static func fetchBuildings(lat: Double, lon: Double) async throws -> [Layer.Feature] {
        let (tileId, xFrac, yFrac) = latLonToTileId(lat: lat, lon: lon, zoom: 15)
        let headerData = try await fetchMapBytes(from: 0, to: 16484)

        let header = headerData.withUnsafeBytes { d in
            func unalignedInt32(offset: Int) -> Int32 {
                var tmp: Int32 = 0;
                memcpy(&tmp, d.baseAddress!.advanced(by: offset), MemoryLayout<Int32>.size);
                return Int32(littleEndian: tmp)
            }

            return (
                specVersion         : d.load(fromByteOffset: 7  , as: UInt8 .self),
                rootDirectoryOffset : d.load(fromByteOffset: 8  , as: UInt64.self),
                rootDirectoryLength : d.load(fromByteOffset: 16 , as: UInt64.self),
                jsonMetadataOffset  : d.load(fromByteOffset: 24 , as: UInt64.self),
                jsonMetadataLength  : d.load(fromByteOffset: 32 , as: UInt64.self),
                leafDirectoryOffset : d.load(fromByteOffset: 40 , as: UInt64.self),
                leafDirectoryLength : d.load(fromByteOffset: 48 , as: UInt64.self),
                tileDataOffset      : d.load(fromByteOffset: 56 , as: UInt64.self),
                tileDataLength      : d.load(fromByteOffset: 64 , as: UInt64.self),
                numAddressedTiles   : d.load(fromByteOffset: 72 , as: UInt64.self),
                numTileEntries      : d.load(fromByteOffset: 80 , as: UInt64.self),
                numTileContents     : d.load(fromByteOffset: 88 , as: UInt64.self),
                clustered           : d.load(fromByteOffset: 96 , as: UInt8 .self) == 1,
                internalCompression : d.load(fromByteOffset: 97 , as: UInt8 .self),
                tileCompression     : d.load(fromByteOffset: 98 , as: UInt8 .self),
                tileType            : d.load(fromByteOffset: 99 , as: UInt8 .self),
                minZoom             : d.load(fromByteOffset: 100, as: UInt8 .self),
                maxZoom             : d.load(fromByteOffset: 101, as: UInt8 .self),
                minLon              : unalignedInt32(offset: 102) / 10000000,
                minLat              : unalignedInt32(offset: 106) / 10000000,
                maxLon              : unalignedInt32(offset: 110) / 10000000,
                maxLat              : unalignedInt32(offset: 114) / 10000000,
                centerZoom          : unalignedInt32(offset: 118),
                centerLon           : unalignedInt32(offset: 119) / 10000000,
                centerLat           : unalignedInt32(offset: 123) / 10000000,
            );
        }

        var entries: [Entry]
        do {
            let start = header.rootDirectoryOffset + GZIP_HEADER_SIZE
            let end = start + header.rootDirectoryLength
            entries = try parseDirectory(compressedData: headerData[start...end])
        }

        func findTile(_ entries: [Entry], _ tileId: UInt64) -> Entry? {
            var m = 0
            var n = entries.count - 1
            while m <= n {
                let k = (n + m) >> 1
                let cmp = Int(tileId) - Int(entries[k].tileId)

                if cmp > 0 {
                    m = k + 1
                } else if cmp < 0 {
                    n = k - 1
                } else {
                    return entries[k]
                }
            }

            if n >= 0 {
                if entries[n].runLength == 0 {
                    return entries[n]
                }
                if (tileId - entries[n].tileId) < entries[n].runLength {
                    return entries[n]
                }
            }

            return nil
        }

        for _ in 0...3 {
            if let entry = findTile(entries, tileId) {
                let eFrom = entry.offset + GZIP_HEADER_SIZE
                let eTo = entry.length + eFrom

                if entry.runLength > 0 {
                    let compressedData = try await fetchMapBytes(
                        from: header.tileDataOffset + eFrom,
                        to:   header.tileDataOffset + eTo
                    );
                    let buildings = try parseTile(compressedData: compressedData)
                    return sortBuildingsByCloseness(buildings, x: xFrac, y: yFrac)
                } else {
                    let compressedData = try await fetchMapBytes(
                        from: header.leafDirectoryOffset + eFrom,
                        to:   header.leafDirectoryOffset + eTo
                    );
                    entries = try parseDirectory(compressedData: compressedData)
                }
            }
        }

        return []
    }

    static func parseDirectory(compressedData: Data) throws -> [Entry] {
        let data = try! (compressedData as NSData)
            .decompressed(using: .zlib) as Data

        var bds = BinaryDataStream(data: data)

        let numEntries = Int(try bds.readVarint())
        var entries: [Entry] = []

        var lastId: UInt64 = 0;
        for _ in 0..<numEntries {
            let v = UInt64(try bds.readVarint())
            entries.append(Entry(tileId: v + lastId, offset: 0, length: 0, runLength: 1))
            lastId += v
        }

        for i in 0..<numEntries {
            entries[i].runLength = try bds.readVarint()
        }

        for i in 0..<numEntries {
            entries[i].length = try bds.readVarint()
        }

        for i in 0..<numEntries {
            let v = try bds.readVarint()
            if v == 0 && i > 0 {
                entries[i].offset = entries[i - 1].offset + entries[i - 1].length
            } else {
                entries[i].offset = v - 1
            }
        }

        return entries
    }

    static func parseTile(compressedData: Data) throws -> [Layer.Feature] {
        let data = try! (compressedData as NSData).decompressed(using: .zlib) as Data

        var bds = BinaryDataStream(data: data)

        while bds.i != bds.data.count {
            let layer = try bds.readLayer()
            if layer.name == "buildings" {
                return layer.features
            }
        }
        return []
    }
}

struct BinaryDataStream {
    var data: Data
    var i: UInt64 = 0

    enum E: Error {
        case VarintTooBig
        case InvalidString
        case UnknownType
    }

    mutating func readByte() -> UInt8 {
        let b = data[Int(i)]
        i += 1
        return b
    }

    mutating func readVarint() throws -> UInt64 {
        var output: UInt64 = 0
        var counter = 0
        var shifter: UInt64 = 0

        while true {
            let byte = readByte()

            if byte < 0x80 {
                if counter > 9 || counter == 9 && byte > 1 {
                    return 0
                }
                return output | UInt64(byte) << shifter
            }

            output |= UInt64(byte & 0x7f) << shifter
            shifter += 7
            counter += 1
        }

        return 0
    }

    mutating func readSVarint() throws -> Int64 {
        let unsignedValue = try readVarint()
        var value = Int64(unsignedValue >> 1)

        if unsignedValue & 1 != 0 { value = ~value }

        return value
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

    mutating func skipField(type: UInt64) throws {
        enum PBF: UInt64 {
            case Varint = 0
            case Bytes = 2
            case Fixed32 = 5
            case Fixed64 = 1
        }

        guard let pbf = PBF(rawValue: type & 0b111) else { throw E.UnknownType }
        switch pbf {
            case PBF.Varint:
                while (data[Int(i)] > 0x7f) { i += 1 } 
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

        var cmd: UInt64 = 1
        var length: UInt64 = 0

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
                x += Int(try readSVarint())
                y += Int(try readSVarint())

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
