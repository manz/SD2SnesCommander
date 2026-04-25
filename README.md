# SD2Snes Commander

macOS app and CLI for the [SD2SNES / FX PAK Pro](https://sd2snes.de/) flash
cart. Browse the SD card over USB, upload patched ROMs, boot games, return to
the menu — from a SwiftUI window or from the shell.

## Layout

- **SD2SnesCommander.app** — SwiftUI front end. Two-column file browser, drag
  and drop uploads, IPS auto-patching, return-to-menu and reset controls.
- **sd2snes** CLI — bundled at `Contents/Helpers/sd2snes` inside the app.
  Same operations as the GUI, plus a kitty/ghostty taskbar progress bar
  during transfers.
- **SD2SnesUSBService** — bundled XPC service that owns the USB device.
  Lets the GUI and the CLI share the cartridge instead of fighting over
  exclusive access.
- **SD2snesCommanderCore.framework** — Swift wrapper around a tiny C IOKit
  driver (`sd2snes_usb.c`) that speaks the SD2SNES USB protocol.
- **SD2SNES_USB_Protocol.md** — annotated protocol notes derived from the
  upstream firmware source.

## Building

Requires Xcode 26 and macOS 26.4 or newer (deployment target).

```sh
xcodebuild -project SD2SnesCommander.xcodeproj \
           -scheme SD2SnesCommander \
           -configuration Debug build
```

The build produces `.../Debug/SD2SnesCommander.app` containing the app, the
embedded CLI and the XPC service, all signed ad-hoc.

To enable the verbose USB trace (off by default) add
`GCC_PREPROCESSOR_DEFINITIONS=SD2SNES_DEBUG=1` to the build.

## Tests

```sh
xcodebuild -project SD2SnesCommander.xcodeproj \
           -scheme SD2SnesCommander \
           -destination 'platform=macOS' test
```

The unit tests cover the IPS patcher, the C↔Swift error mapping, the
`RemoteInfo` decoder, gaming-state detection and navigation history. They do
not touch a real device.

## Installing the CLI

Drag the app into `/Applications` then either pick *Install Command Line
Tool…* from the SD2Snes Commander menu, or symlink it manually:

```sh
sudo ln -sf "/Applications/SD2SnesCommander.app/Contents/Helpers/sd2snes" \
            /usr/local/bin/sd2snes
```

`sd2snes help` lists the available commands.

## Distribution caveats

The project uses ad-hoc code signing only. macOS Gatekeeper will warn anyone
who isn't the building developer; right-click → *Open* dismisses it once, or
strip the quarantine attribute:

```sh
xattr -dr com.apple.quarantine /Applications/SD2SnesCommander.app
```

Notarization requires a paid Apple Developer Program membership and is not
configured.

## License

[GPL-2.0](LICENSE), matching the upstream sd2snes firmware. The host code in
this repository does not link or include any firmware source — it only
talks to the device over USB.
