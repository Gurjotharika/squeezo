# Screen recording for App Review

Apple asks for a recording from a physical device running the latest OS. Use your Mac running the latest macOS with the App Store build (TestFlight or the build you submitted), not a simulator.

## Record
1. Make a folder on the Desktop called "Squeezo Demo" with one JPEG photo, one PDF and one short video.
2. Quit Squeezo. Open QuickTime Player, choose File, New Screen Recording, pick the whole screen, and press Record.
3. Follow the steps below at a calm pace. Aim for 2 to 3 minutes.
4. Stop with the menu bar stop button. Save as an .mov or .mp4 and attach it to the reply.

## Steps (this is the typical flow Apple wants to see)
1. Launch Squeezo from the Dock or Launchpad, so the recording begins with the app starting.
2. Show the Compress screen. Drag the three demo files in from the folder. Point at the right panel for details.
3. Press the Compress button. When the app asks for a folder, allow it. Show the results with sizes before and after.
4. Show the Undo/restore flow once: run with "Replace original", then undo from the result.
5. Choose Crop in the sidebar, add the photo, drag the crop corners, run it.
6. Choose Merge PDFs or Convert, add files, run it.
7. Open Settings and show the Help links and Restore Purchases.
8. Show paid features: click "Unlock everything" at the bottom of the sidebar, show the paywall with both plans, and make a purchase with a Sandbox Apple Account (or TestFlight, which uses the sandbox). Show the "thank you" screen, then show a Pro feature: Settings, Watched Folders.
9. Optionally show Restore Purchases.

## Not needed for this app
There is no account registration, login, account deletion or user-generated content, so none of those flows exist to record. Say so in the reply.

## Recording that is already made
`Marketing/Squeezo-App-Review-Demo.mov` (about 1 minute, 1360x760) was recorded on a physical Mac running macOS 27 with `.tools/record.sh`. It starts from the freshly launched app and shows: dragging files in from Finder, compressing them with before and after sizes, the save location menu, the Convert tool, Settings (General and Watched Folders), and the Squeezo Pro window with Restore Purchases, Terms of Use and Privacy Policy links.

It does not show a completed purchase, because that needs a Sandbox Apple Account. If App Review asks for it, record steps 8 and 9 above from your TestFlight build and attach that as well.
