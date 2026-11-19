# ScreenVeil 0.3.0

ScreenVeil is a native Swift menu-bar utility for macOS 14 or later. It supports Apple silicon and Intel Macs.

## Use

1. Quit any previous copy of ScreenVeil, then move the new `ScreenVeil.app` to Applications and open it.
2. Allow ScreenVeil in **Accessibility** and **Input Monitoring**. Reopen the app if macOS asks. Granted permissions disappear from Settings.
3. Press and release **⌘⇧L** to blur every display and pause keyboard and pointer input. Press and release the same shortcut to restore input.
4. To change the shortcut, click it in Settings and press a combination with Command, Option, or Control. Esc cancels recording. **Show unlock shortcut** controls whether the shortcut is printed on the overlay.

ScreenVeil appears in the Dock and the app switcher while Settings is open. Closing Settings returns it to the menu bar. For password protection, use the macOS Lock Screen. The Xcode project uses local ad hoc signing, so it builds without a developer certificate.

## Karabiner-Elements

With Karabiner-Elements 15.6.0 or later, choose **Settings → Karabiner → Enable…**. ScreenVeil backs up `karabiner.json` and adds a condition to applicable complex modifications that run scripts, system actions, or input source switches. These actions pause during a ScreenVeil lock and resume at unlock. If ScreenVeil exits unexpectedly, the condition expires within 12 seconds of its last refresh. Choose **Disable** to remove ScreenVeil’s conditions.

If you add more Karabiner rules later, **Update…** adds the same condition to newly detected rules. Ordinary key remaps still go through the macOS input filter.

## Build

Open `ScreenVeil.xcodeproj` in Xcode and run the ScreenVeil scheme. `project.yml` can regenerate the project using XcodeGen.

The icon is built from unmasked square artwork with a G2-continuous outline. Run `bash Branding/build-icon.sh` to regenerate the PNG and ICNS.
