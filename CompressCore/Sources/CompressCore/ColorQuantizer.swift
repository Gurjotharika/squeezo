import Foundation

/// Reduces an RGBA image to a palette using median cut, with optional Floyd–Steinberg dithering.
enum ColorQuantizer {
    struct Result {
        var palette: [RGBA8]
        var indices: [UInt8]
    }

    /// Returns an exact palette if the image has at most `limit` distinct colours, otherwise nil.
    /// Fully transparent pixels count as one colour whatever their hidden RGB values.
    static func exactPalette(pixels: [UInt8], limit: Int = 256) -> Result? {
        let limit = min(limit, 256)  // palette indices are bytes
        var lookup: [UInt32: UInt8] = [:]
        var palette: [RGBA8] = []
        var indices = [UInt8](repeating: 0, count: pixels.count / 4)

        for i in 0..<indices.count {
            let a = pixels[i * 4 + 3]
            let r = a == 0 ? 0 : pixels[i * 4]
            let g = a == 0 ? 0 : pixels[i * 4 + 1]
            let b = a == 0 ? 0 : pixels[i * 4 + 2]
            let key = UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
            if let index = lookup[key] {
                indices[i] = index
            } else {
                guard palette.count < limit else { return nil }
                let index = UInt8(palette.count)
                lookup[key] = index
                palette.append(RGBA8(r: r, g: g, b: b, a: a))
                indices[i] = index
            }
        }
        return Result(palette: palette, indices: indices)
    }

    /// Builds a palette of at most `maxColors` entries from straight RGBA pixels. If any pixel is fully
    /// transparent, the last entry is a transparent colour and its index is returned.
    static func buildPalette(pixels: [UInt8], maxColors: Int) -> (palette: [RGBA8], transparentIndex: UInt8?) {
        let maxColors = min(max(maxColors, 2), 256)
        let count = pixels.count / 4

        // 1. Histogram on 5-5-5-4 bit buckets.
        let bucketCount = 1 << 19
        var population = [UInt32](repeating: 0, count: bucketCount)
        var sums = [UInt64](repeating: 0, count: bucketCount * 4)
        var hasTransparent = false

        pixels.withUnsafeBufferPointer { px in
            for i in 0..<count {
                let a = px[i * 4 + 3]
                if a == 0 {
                    hasTransparent = true
                    continue
                }
                let r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2]
                let key = bucket(r, g, b, a)
                population[key] += 1
                sums[key * 4] += UInt64(r)
                sums[key * 4 + 1] += UInt64(g)
                sums[key * 4 + 2] += UInt64(b)
                sums[key * 4 + 3] += UInt64(a)
            }
        }

        var entries: [Entry] = []
        for key in 0..<bucketCount where population[key] > 0 {
            let n = Float(population[key])
            entries.append(Entry(
                count: population[key],
                c: [Float(sums[key * 4]) / n, Float(sums[key * 4 + 1]) / n,
                    Float(sums[key * 4 + 2]) / n, Float(sums[key * 4 + 3]) / n]))
        }

        // 2. Median cut.
        let budget = hasTransparent ? maxColors - 1 : maxColors
        var palette = medianCut(&entries, colors: max(budget, 1))
        var transparentIndex: UInt8?
        if hasTransparent {
            transparentIndex = UInt8(palette.count)
            palette.append(RGBA8(r: 0, g: 0, b: 0, a: 0))
        }
        if palette.isEmpty { palette = [RGBA8(r: 0, g: 0, b: 0, a: 0)] }
        return (palette, transparentIndex)
    }

    static func quantize(
        pixels: [UInt8],
        width: Int,
        height: Int,
        maxColors: Int,
        ditherStrength: Float
    ) -> Result {
        let count = width * height
        let bucketCount = 1 << 19
        let (palette, transparentIndex) = buildPalette(pixels: pixels, maxColors: maxColors)

        // 3. Map pixels to the palette, diffusing the error.
        var indices = [UInt8](repeating: 0, count: count)
        var cache = [Int16](repeating: -1, count: bucketCount)
        let paletteF = palette.map { [Float($0.r), Float($0.g), Float($0.b), Float($0.a)] }

        func nearest(_ c: [Float]) -> UInt8 {
            let r = UInt8(max(0, min(255, c[0].rounded())))
            let g = UInt8(max(0, min(255, c[1].rounded())))
            let b = UInt8(max(0, min(255, c[2].rounded())))
            let a = UInt8(max(0, min(255, c[3].rounded())))
            let key = bucket(r, g, b, a)
            if cache[key] >= 0 { return UInt8(cache[key]) }
            var best = 0
            var bestDistance = Float.greatestFiniteMagnitude
            for (i, p) in paletteF.enumerated() where i != Int(transparentIndex ?? 255) || transparentIndex == nil {
                let d = distance(c, p)
                if d < bestDistance {
                    bestDistance = d
                    best = i
                }
            }
            cache[key] = Int16(best)
            return UInt8(best)
        }

        var errorRow = [Float](repeating: 0, count: (width + 2) * 4)
        var nextRow = [Float](repeating: 0, count: (width + 2) * 4)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if pixels[i * 4 + 3] == 0, let t = transparentIndex {
                    indices[i] = t
                    continue
                }
                var c: [Float] = [Float(pixels[i * 4]), Float(pixels[i * 4 + 1]),
                                  Float(pixels[i * 4 + 2]), Float(pixels[i * 4 + 3])]
                if ditherStrength > 0 {
                    for k in 0..<4 { c[k] = max(0, min(255, c[k] + errorRow[(x + 1) * 4 + k])) }
                }
                let index = nearest(c)
                indices[i] = index
                guard ditherStrength > 0 else { continue }
                let chosen = paletteF[Int(index)]
                for k in 0..<4 {
                    let e = (c[k] - chosen[k]) * ditherStrength
                    errorRow[(x + 2) * 4 + k] += e * 7 / 16
                    nextRow[x * 4 + k] += e * 3 / 16
                    nextRow[(x + 1) * 4 + k] += e * 5 / 16
                    nextRow[(x + 2) * 4 + k] += e * 1 / 16
                }
            }
            errorRow = nextRow
            nextRow = [Float](repeating: 0, count: (width + 2) * 4)
        }
        return Result(palette: palette, indices: indices)
    }

    // MARK: Median cut

    private struct Entry {
        var count: UInt32
        var c: [Float]  // r, g, b, a
    }

    private static func medianCut(_ entries: inout [Entry], colors: Int) -> [RGBA8] {
        guard !entries.isEmpty else { return [] }
        var boxes = [0..<entries.count]

        while boxes.count < colors {
            // Split the box where a split matters most: many pixels and a wide colour range.
            var bestBox = -1
            var bestScore: Float = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let (_, range) = widestChannel(entries, box)
                let total = entries[box].reduce(Float(0)) { $0 + Float($1.count) }
                let score = range * total.squareRoot()
                if score > bestScore {
                    bestScore = score
                    bestBox = i
                }
            }
            guard bestBox >= 0 else { break }

            let box = boxes[bestBox]
            let (channel, _) = widestChannel(entries, box)
            entries[box].sort { $0.c[channel] < $1.c[channel] }

            let total = entries[box].reduce(UInt64(0)) { $0 + UInt64($1.count) }
            var running: UInt64 = 0
            var split = box.lowerBound + 1
            for i in box {
                running += UInt64(entries[i].count)
                if running * 2 >= total {
                    split = min(max(i + 1, box.lowerBound + 1), box.upperBound - 1)
                    break
                }
            }
            boxes[bestBox] = box.lowerBound..<split
            boxes.append(split..<box.upperBound)
        }

        return boxes.map { box in
            var total: Float = 0
            var sum: [Float] = [0, 0, 0, 0]
            for e in entries[box] {
                let n = Float(e.count)
                total += n
                for k in 0..<4 { sum[k] += e.c[k] * n }
            }
            func channel(_ k: Int) -> UInt8 { UInt8(max(0, min(255, (sum[k] / total).rounded()))) }
            return RGBA8(r: channel(0), g: channel(1), b: channel(2), a: channel(3))
        }
    }

    private static func widestChannel(_ entries: [Entry], _ box: Range<Int>) -> (Int, Float) {
        var low: [Float] = [255, 255, 255, 255]
        var high: [Float] = [0, 0, 0, 0]
        for e in entries[box] {
            for k in 0..<4 {
                low[k] = min(low[k], e.c[k])
                high[k] = max(high[k], e.c[k])
            }
        }
        // Weigh channels roughly by how visible errors in them are.
        let weights: [Float] = [0.8, 1.0, 0.6, 0.8]
        var best = 0
        var bestRange: Float = -1
        for k in 0..<4 {
            let range = (high[k] - low[k]) * weights[k]
            if range > bestRange {
                bestRange = range
                best = k
            }
        }
        return (best, bestRange)
    }

    private static func distance(_ a: [Float], _ b: [Float]) -> Float {
        let dr = a[0] - b[0], dg = a[1] - b[1], db = a[2] - b[2], da = a[3] - b[3]
        return 0.64 * dr * dr + dg * dg + 0.36 * db * db + 0.64 * da * da
    }

    private static func bucket(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Int {
        Int(r >> 3) << 14 | Int(g >> 3) << 9 | Int(b >> 3) << 4 | Int(a >> 4)
    }
}
