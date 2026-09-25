# Orb

Your Dock, in the colors of what you're playing.

Orb is a tiny macOS app with no window, no menu and no controls. While Apple Music plays, the bottom of your screen and the Dock take on the colors of the current album artwork, as a slow, blurred swirl of the cover itself.

- **Music starts:** the Dock and the screen edge gently fade into the album's colors.
- **Song changes:** the new cover blooms out from the middle of the screen and melts into the old one.
- **Music pauses:** the motion settles, and after two seconds the Dock fades back to normal.
- **Music stops or quits:** the Dock returns to normal.

## Requirements

- macOS 14 or later (designed for macOS 26's Liquid Glass Dock)
- Apple Music
- Xcode or the Xcode Command Line Tools, to build

## Build and run

```bash
./build.sh --run
```

This compiles `build/Orb.app` and opens it. To keep it around, drag `build/Orb.app` into `/Applications`.

On first launch macOS asks for two permissions:

1. **Accessibility** (System Settings → Privacy & Security → Accessibility). Orb uses it only to find where the Dock is drawn. Nothing appears until this is on.
2. **Automation → Music**, to read the current song and its artwork.

**To turn Orb off**, open it again: it fades out and quits. You can also quit it from Activity Monitor or with `pkill -x Orb`.

**To start it at login**, add `Orb.app` under System Settings → General → Login Items.

## How it works

macOS doesn't let apps draw inside the Dock. The Dock's background, though, is translucent glass that blurs whatever sits behind it. Orb places a borderless, click-through window along the Dock's edge of the screen, one level below the Dock, and paints there. Nothing in the system is modified.

The glow is shown twice from the same image:

- **A floor of light** across the whole screen edge. It's strongest at the edge and fades to nothing before the top of the area macOS reserves for the Dock, so it has no visible edge and never tints app windows.
- **Behind the Dock's glass**, aligned exactly with the floor and a little brighter. The glass blurs and tints it, so the Dock reads as the brightest part of one continuous light rather than a colored object.

`floorIntensity` and `dockIntensity` in `Sources/DockBackdrop.swift` control the two strengths.

- **Music state** comes from Apple Music's `com.apple.Music.playerInfo` distributed notification, which is instant and costs nothing.
- **Artwork** is read from Music via AppleScript. Streamed Apple Music songs that aren't in your library don't expose artwork to scripts, so for those Orb looks up the official cover with Apple's public iTunes Search API.
- **The glow** is a 20×20 blurred copy of the cover in the OKLab color space. It's sampled through a slowly drifting, tilting window and bent by flowing noise. Saturation is capped per hue so blues and violets don't overpower warm colors. It's rendered at a quarter of the Dock's resolution and scaled up, which works out to roughly 2% CPU while playing.
- **The Dock's position and size** come from the Accessibility API.

## Privacy

Songs in your library never leave your Mac. For streamed songs without local artwork, Orb sends the song title, artist and album to `itunes.apple.com` to find the cover. Nothing else is collected or sent.

## Notes

- `build.sh` signs the app with an ad-hoc signature, which changes on every build. macOS ties the Accessibility permission to the signature, so after each rebuild you have to grant it again:

  ```bash
  tccutil reset Accessibility com.orbdock.Orb
  ```

  Then relaunch Orb and allow the prompt.
- With an auto-hiding Dock, the glow follows the Dock as it slides in and out but can trail it by a frame or two.

## Project layout

| File | Purpose |
| --- | --- |
| `Sources/main.swift` | App lifecycle, reacting to music changes, frame loop |
| `Sources/Music.swift` | Apple Music state, artwork, catalog lookup |
| `Sources/Swatch.swift` | Blurred artwork texture and per-hue saturation limits |
| `Sources/Glow.swift` | Animation state and the flowing-color renderer |
| `Sources/DockBackdrop.swift` | The floor-of-light window, the layer behind the Dock, and Dock location |
| `Sources/Color.swift` | OKLab color conversions |
| `Resources/Info.plist` | App metadata and permission descriptions |
| `build.sh` | Builds, icons and signs `build/Orb.app` |
