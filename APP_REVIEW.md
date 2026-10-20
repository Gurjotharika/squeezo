# App Review reply for Squeezo

Paste sections 2 to 6 into the reply in App Store Connect. Paste the "Notes field" block into App Review Information, Notes.
Record the video from `RECORDING.md` and attach it to the reply.

## 2. Purpose and audience
Squeezo is an all-in-one file toolbox for the Mac. It makes photos, videos, GIFs, PDFs and audio smaller, and also resizes, crops, rotates, converts, merges and splits files, adds watermarks, hides faces, removes backgrounds and extracts text. Everything runs on the user's Mac.

It is for anyone who needs smaller or tidier files without uploading them: people sending photos and videos by email or chat, students and office workers with scanned PDFs, creators and developers preparing images, and anyone who handles private files that must not leave their computer.

The problem it solves is that file tools are usually web services that upload files, or separate apps for each job. Squeezo gives one native, offline app with a clear before-and-after view of every file.

## 3. How to use the app (no login, no account)
There is no sign-in. Open the app and drag any photo, video, GIF, PDF or audio file onto the window, or choose File, Add Files. Any files on the reviewer's Mac will work. A JPEG photo and a PDF are the quickest to test.
1. Pick a tool in the sidebar (Compress is the default).
2. Check the options in the right-hand panel.
3. Press the button at the bottom to run it, then choose where results are saved (next to the original, a folder, or replace the original with Undo).
Because of the App Sandbox, the app asks the reviewer to choose files and folders.
Free use is limited to 5 files a day. The paywall opens from the "Unlock everything" button at the bottom of the sidebar, or from Settings. Squeezo Pro is a lifetime purchase (com.squeezo.lifetime) or a yearly subscription (com.squeezo.yearly). Restore Purchases is in the Pro window and Settings. Pro adds no daily limit, watched folders and Shortcuts actions.

## 4. External services and tools
- Apple App Store and StoreKit 2: the only external service, used for purchases, subscriptions and Restore Purchases.
- Apple system frameworks on the device: ImageIO, AVFoundation, VideoToolbox, PDFKit, Core Graphics, Core Image, Vision (face detection, text recognition, background removal), Compression, App Intents and ServiceManagement.
- No third-party SDKs, no data providers, no authentication service, no analytics, no advertising and no AI services. The app has no network entitlement and makes no network requests of its own.

## 5. Regional differences
The app works the same in all regions. Prices are set by the App Store for each storefront. There is no region-specific content or features.

## 6. Regulated industry or protected material
Not applicable. The app is not in a regulated industry and includes no third-party protected material. Users process only their own files. Face detection is used only on the user's device to blur faces in the user's own pictures.

## Notes field (paste into App Review Information)
```
Squeezo is an offline file toolbox for Mac. It compresses, resizes, crops, converts, merges and edits photos, videos, GIFs, PDFs and audio. No account or login. Nothing is uploaded; the app has no network permission.

To test: drag any photo, video or PDF onto the window (or File > Add Files). Pick a tool in the sidebar, check options on the right, press the button at the bottom, and choose where results are saved. The sandbox asks the reviewer to choose files and folders.

Free use is 5 files per day. Squeezo Pro (lifetime com.squeezo.lifetime, or yearly com.squeezo.yearly) removes the limit and adds watched folders and Shortcuts actions. The paywall opens from the "Unlock everything" button at the bottom of the sidebar, or from Settings. Restore Purchases is in the Pro window and Settings.

External services: Apple App Store / StoreKit 2 for purchases only. All processing uses Apple frameworks on the device (ImageIO, AVFoundation, VideoToolbox, PDFKit, Core Image, Vision). No third-party SDKs, analytics, ads or AI services.

Features and content are the same in all regions. No regulated industry, no third-party protected content, no user-generated content, no account creation or deletion.

Terms: https://squeezo.framer.website/terms
Privacy: https://squeezo.framer.website/privacy
Support: https://squeezo.framer.website/support
```
