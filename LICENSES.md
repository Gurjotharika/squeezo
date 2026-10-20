# Third-party licenses

The app contains no third-party code. Compression is done with Apple's system frameworks
(ImageIO, AVFoundation, VideoToolbox, PDFKit, Core Graphics, Compression) and with code written for this project:

- PNG palette encoder and median-cut quantizer (`PNGEncoder`, `ColorQuantizer`)
- GIF encoder with frame differencing (`GIFEncoder`, `GIFOptimizer`)
- PDF object parser and rewriter (`PDFFile`, `PDFRewriter`, `PDFImageRecompressor`)
- ZIP reader and writer for EPUB and Office files (`ZipArchive`)
- Image, video, GIF and PDF editing tools built on Core Image, Vision (face detection, text recognition, subject masks) and PDFKit

Add every new dependency here with its license before using it. Mac App Store rule: no GPL or AGPL code.
Candidates considered and not used: ffmpeg and Ghostscript (GPL/AGPL), gifski (AGPL).
Possible later addition: libwebp (BSD) for writing WebP, mozjpeg (BSD-style) for smaller JPEGs.
