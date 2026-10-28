# E-kirjasto Audiobook Toolkit

An iOS framework for audiobook playback in the E-kirjasto iOS app.

## Build

Requirements:

- Xcode 27.1
- iOS 15 or later

Open `PalaceAudiobookToolkit.xcodeproj` and build **PalaceAudiobookToolkit** target.

## Integration

Add the framework using Carthage:

```text
github "ThePalaceProject/ios-audiobooktoolkit"
```

Open Access support is included. Other DRM providers may require separate
licenses.

The host application must enable the **Background Modes** capability with
audio playback enabled.
