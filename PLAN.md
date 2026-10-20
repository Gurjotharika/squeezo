# Compress: Development Plan

A native macOS app (SwiftUI) that batch-compresses images, video, GIFs and PDFs in one place. All processing happens on the Mac, nothing is uploaded. Distributed through the Mac App Store.

## Ground rules
- **Platform:** SwiftUI, Swift 6 concurrency, macOS 14+ (open decision).
- **App Store constraints:** App Sandbox, no GPL/AGPL code, no helper executables, no network, StoreKit 2 for payments, no Sparkle.
- **Engines:** Apple frameworks first (ImageIO, AVFoundation/VideoToolbox, PDFKit, Core Graphics). Add permissively licensed libraries only where Apple's are not good enough.
- **Structure:** `CompressCore` (local Swift package, no UI) + `Compress` (app target).
- **Done means:** builds clean, tests pass, sandboxed build runs, and size/quality checked against the sample corpus.

## Open decisions
| # | Decision | Default if not answered |
|---|---|---|
| 1 | Minimum macOS | 14 |
| 2 | Free-tier limits | 5 files per day |
| 3 | Xcode project generation | XcodeGen (`project.yml`) |
| 4 | App name and bundle ID | `Compress`, `com.<you>.compress` |

---

## Phase 0: Setup (1–2 days) — DONE
- Install XcodeGen, create `project.yml`, app target and `CompressCore` package.
- Sandbox entitlements: user-selected files (read/write), app-scope bookmarks, no network.
- Folder layout, SwiftLint/format config, unit test target.
- Build a **sample corpus** (photos, screenshots, PNG with transparency, HEIC, 4K video, short clip, scanned PDF, text PDF, GIF).
- **Exit:** empty app launches under the sandbox, tests run.

## Phase 1: Core engine and queue (3–4 days) — DONE
- Models: `MediaKind`, `CompressionJob`, `Preset`, `OutputPolicy` (replace original / suffix / chosen folder), `JobResult`.
- `Compressor` protocol with progress and cancellation.
- `JobQueue` actor: concurrency limit, states (queued, running, done, failed, cancelled), retry.
- File type detection by UTType, not extension.
- **Exit:** queue runs a fake compressor, with tests for cancel, failure and ordering.

## Phase 2: App shell and drag-and-drop (3 days) — DONE
- Main window: drop area, file list with thumbnails, per-file progress, size before/after, total savings.
- Add files via drag-and-drop, folder drop (recursive), open panel, Finder "Open With".
- Output location handling with security-scoped access.
- Preset picker (Highest / High / Medium / Low) in the toolbar.
- **Exit:** drop files, see them queue and complete (still with the fake compressor).

## Phase 3: Image compression (1 week) — DONE except WebP output and mozjpeg
Notes: ImageIO cannot write WebP, so WebP is left unchanged until libwebp (BSD) is added. mozjpeg is optional and not yet evaluated. PNG palette path is our own encoder (median cut + dithering). Quality checked with SSIM on synthetic images.

- JPEG, PNG, HEIC, WebP, TIFF via ImageIO.
- Quality slider, optional resize, EXIF/metadata stripping, color profile handling.
- PNG optimisation (quantization or lossless recompression) and WebP encoding via bundled libraries after license check.
- Never output a larger file than the input; keep the original in that case.
- **Exit:** corpus images compress with visual quality checks (SSIM threshold) and measured savings.

## Phase 4: Video compression (1.5 weeks) — DONE
Notes: constant-quality encoding (not a fixed bitrate), which saved far more on real footage. HDR is kept as 10-bit HEVC. A watchdog fails stuck decoders after 45 seconds.
- AVAssetReader/Writer pipeline with H.264 and HEVC through VideoToolbox.
- Presets for resolution, bitrate/quality and frame rate; audio passthrough or re-encode.
- MP4 and MOV output, progress by time, cancel, clean-up of partial files.
- Handle rotation, HDR/Dolby Vision, variable frame rate, files with no audio track.
- **Exit:** 4K clip compresses with sensible size reduction and plays correctly on Mac and iPhone.

## Phase 5: GIF and video to GIF (1 week) — DONE
- GIF optimisation: palette reduction, frame dedup, lossy option.
- Video to GIF: trim range, fps, width, loop.
- **Exit:** corpus GIF reduced and animation intact.

## Phase 6: PDF compression (1 week) — DONE
Notes: own PDF rewriter that re-encodes large images and copies everything else byte for byte. Encrypted files are left alone.
- PDFKit/Core Graphics: downsample and re-encode embedded images, strip metadata.
- Presets by target DPI. Keep text and vectors selectable.
- Skip or warn on encrypted PDFs.
- **Exit:** scanned and image-heavy PDFs shrink a lot, text PDFs are never made worse.

## Phase 7: Automation (1 week) — DONE
Notes: Raycast and scripts should use `open -a Compress <files>`; the sandbox does not allow reading paths passed in a URL.
- Floating Drop Zone panel (`NSPanel`) usable without opening the main window.
- `MenuBarExtra` with recent jobs and quick actions.
- Watched folders: `NSOpenPanel` selection, bookmarks, FSEvents, debounce, wait-until-file-finished, avoid re-processing own output, per-folder preset.
- App Intents (Shortcuts and Spotlight) and a custom URL scheme for Raycast.
- Launch at login via `SMAppService`.
- **Exit:** a file dropped into a watched folder is compressed once, with no loops.

## Phase 8: Settings, polish, extras (1 week) — DONE
Notes: added audio (AAC) and zip-based documents (EPUB, docx, pptx, xlsx). Replacing originals now moves them to the Trash and can be undone.
- Settings: default preset, output policy, concurrency, notifications, sounds.
- Result details (reveal in Finder, undo/restore original, trash handling).
- Accessibility (VoiceOver, keyboard navigation), dark mode, localization scaffolding.
- Optional extras: EPUB, audio, extra formats such as AVIF.

## Phase 9: Monetisation (3–4 days) — DONE (needs App Store Connect setup)
- StoreKit 2: free tier with limits, one-time unlock, optional subscription, restore purchases.
- Paywall and limit messaging, StoreKit configuration file for testing.
- **Exit:** purchase, restore and limit enforcement all work in the StoreKit sandbox.

## Phase 10: Hardening and release (1–2 weeks) — code DONE; store steps are in RELEASE.md
- Performance and memory profiling on large batches (hundreds of files).
- Edge cases: read-only volumes, iCloud placeholders, huge files, corrupt inputs, low disk space.
- Privacy manifest (no data collected), App Store listing, screenshots, review notes.
- Code signing, notarisation not needed for MAS but archive validation is, then TestFlight beta and App Review submission.

---

## Risks and mitigations
| Risk | Mitigation |
|---|---|
| Quality vs size tuning decides the product | Benchmark against the sample corpus and competitors from Phase 3 onward |
| PDF compression without Ghostscript | Start with image downsampling; evaluate more only if results are poor |
| Third-party library licenses | Check each license before adding; log in `LICENSES.md` |
| Sandbox surprises (folder access, bookmarks) | Test sandboxed builds from Phase 0, not at the end |
| App Review rejections (paywall, entitlements) | Follow StoreKit and sandbox guidelines, write clear review notes |

## Rough timeline
About 10–12 weeks for one developer. Phases 3–6 can be reordered if a format matters more.


## Phase 11: All-in-one tools — DONE
Beyond compression, the app now has: Resize, Crop, Rotate & Flip, Enlarge (resampling + sharpening, not AI),
Watermark, Hide Faces, Remove Background, Convert (images, video, GIF, audio, PDF pages, images to PDF),
Text & Markdown (with on-device OCR), Merge PDFs and Split PDF. Every tool runs on the Mac.
UI: tools in a sidebar, files in the middle, and an inspector on the right with file details and the tool's options.
Not done: AI super-resolution (VideoToolbox's scaler is macOS 26+ and needs a model download, which the sandbox forbids).
