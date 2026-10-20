# Releasing Squeezo on the Mac App Store

The app is named **Squeezo** in the project. Check that the name is still free when you create the app record
in App Store Connect. If it's taken, change `PRODUCT_NAME` and `INFOPLIST_KEY_CFBundleDisplayName` in `project.yml`
and the `AppInfo.name` constant in `Compress/App/AppInfo.swift`, then regenerate the project with
`.tools/xcodegen/bin/xcodegen generate`.

## Blockers: you must do these before you can submit
1. **Bundle ID and team.** Replace `com.compress.app` (in `project.yml`, two places) with your own, then set your team under
   Signing & Capabilities in Xcode. The URL scheme is `squeezo://`.
2. **Web pages.** Done: the live pages are `https://squeezo.framer.website/privacy`, `/support` and `/terms`, and
   `AppInfo.swift` points at them. Still to do: add your contact email to all three pages (they show a placeholder),
   publish the site, enter the privacy and support URLs in App Store Connect, and use the terms URL as the license
   agreement only if you replace Apple's standard EULA there. Reviewers open the in-app links, so they must be live.
3. **In-app purchases in App Store Connect.** Create exactly these product IDs, or change them in `Store.swift`:
   - `com.squeezo.lifetime`: non-consumable, "Lifetime". Price 29.99 USD.
   - `com.squeezo.yearly`: auto-renewable subscription, 1 year, in a group called "Subscription". Price 9.99 USD a year.
   Fill in display name, description and a review screenshot for each. Subscriptions need the group's localization too.
   Test with a Sandbox Apple Account before submitting.
4. **Copyright line.** Set your name in `INFOPLIST_KEY_NSHumanReadableCopyright` in `project.yml`.
5. **Screenshots.** At least one, up to ten, 1280×800 or larger: the main window with finished files, the Crop editor,
   the Watermark editor, the paywall. Use the Debug build's `-demo` launch option for sample content.

## What is already done (checked against Apple's guidelines)
- **Sandbox (2.4.5):** App Sandbox on; only user-selected read/write and app-scoped bookmarks. No network entitlement,
  no temporary exceptions, no helper tools.
- **Privacy (5.1):** privacy manifest included (`PrivacyInfo.xcprivacy`): no tracking, no data collected, required-reason
  APIs declared. Nothing leaves the Mac. Face detection is only used to blur or cover faces; no face data is kept or sent.
- **In-app purchase (3.1.1, 3.1.2):** features are unlocked with StoreKit; there is a Restore Purchases button; the
  subscription shows price, period, auto-renewal terms, Terms of Use and Privacy Policy links.
  The free tier works without an account and isn't misleading about its limits.
- **Encryption export:** `ITSAppUsesNonExemptEncryption` is `NO`.
- **No placeholder content or private APIs:** debug-only demo code is compiled out of Release builds.
- **Permissions:** the app asks for nothing at launch. Notifications are requested the first time a batch finishes.
  Folder access uses standard open panels.
- **Accessibility:** labels on icon buttons, VoiceOver traits on selection controls, Reduce Motion and Reduce Transparency respected.
- **Version:** 1.0.0 (build 1). Raise the build number for every upload.

## App Store Connect answers
- **Category:** Utilities (secondary: Photo & Video or Productivity).
- **Age rating:** 4+. No objectionable content, no unrestricted web access.
- **App Privacy:** "Data Not Collected".
- **Export compliance:** no encryption beyond Apple's own.
- **Pricing:** free, with the in-app purchases above.
- **Subtitle (30 chars):** Shrink, edit and convert files
- **Promotional text:** Compress, resize, crop, convert, watermark and more. Everything happens on your Mac.
- **Keywords:** compress,resize,crop,convert,pdf,merge,split,watermark,video,image,gif,heic,ocr,markdown
- **Description:** Squeezo is an all-in-one toolbox for photos, videos, GIFs, PDFs and audio. Everything runs on your Mac, so
  your files never leave it.
  • Compress: make files much smaller with no visible loss.
  • Resize, Crop, Rotate, Enlarge.
  • Watermark with text or a logo.
  • Hide faces in pictures and video.
  • Remove backgrounds.
  • Convert between formats, including PDF pages and audio.
  • Turn PDFs and scans into Markdown or text.
  • Merge and split PDFs.
  Free for 5 files a day. Squeezo Pro removes the limit and adds watched folders and Shortcuts.

## Notes for App Review (paste into "App Review Information")
> Squeezo runs entirely offline. Because of the App Sandbox it asks you to pick files or folders: drag any photo,
> video, PDF or audio file onto the window, or use the + button. The first time you save next to a file's original
> location, macOS asks for access to that folder through a standard panel.
> Free users can process 5 files per day. Squeezo Pro (a one-time purchase or a yearly subscription) removes the
> limit and enables Watched Folders in Settings. Use the sandbox Apple Account to test purchases and Restore.
> No account or login is needed. Sample files: any JPEG, MP4 and PDF will do.

## Before you click Submit
1. Product → Archive, then **Validate App**, then **Distribute App → App Store Connect**.
2. Install the TestFlight build on a clean Mac and test: dropping files from Downloads (folder prompt), one tool from each
   group, a watched folder, replace with Undo, a purchase, a restore.
3. Make sure `squeezo.framer.website/privacy`, `/support` and `/terms` are live and show a real contact email.

## Known limits (good to state on your support page)
- WebP files are left unchanged. Encrypted PDFs are left unchanged.
- Enlarge uses resampling and sharpening, not AI.
- Very large videos at 4K and 240 fps may fail to encode; 4K at 120 fps and below worked in testing.
