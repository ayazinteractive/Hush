# Hush

A macOS menu bar app that gives every running app its own volume slider — something
macOS itself doesn't offer. It uses CoreAudio process taps to mute an app's direct
output and replay it at your chosen level, so it needs no kernel driver, no virtual
audio device, and no admin install.

Requires **macOS 15 or later**, on Apple Silicon or Intel.

## Install

### From source

```sh
git clone https://github.com/ayazinteractive/Hush.git
cd Hush
./build.sh --install
```

That builds, copies to `/Applications/Hush.app`, and launches it. Xcode command line
tools are the only prerequisite (`xcode-select --install`).

### From Releases

Download `Hush.zip` from the [latest release](https://github.com/ayazinteractive/Hush/releases),
then:

```sh
unzip Hush.zip
xattr -dr com.apple.quarantine Hush.app
mv Hush.app /Applications/
open /Applications/Hush.app
```

## Permissions and login item

- **System audio recording.** The first time you turn an app down, macOS asks whether
  Hush may record system audio. That is how a process tap works: Hush captures the
  app's sound and plays it back at your level. Nothing is saved or sent anywhere. If
  you said no, allow Hush under System Settings → Privacy & Security → Screen & System
  Audio Recording.
- **Launch at login** is turned on at first launch so your levels keep applying after
  a restart. Turn it off in the menu bar icon's right-click menu.

## Uninstall

```sh
# turn off Launch at Login in the right-click menu first, then:
rm -rf /Applications/Hush.app
defaults delete dev.ayazint.hush
defaults delete com.cryonayes.hush 2>/dev/null   # settings from versions before 1.0
tccutil reset AudioCapture dev.ayazint.hush      # forget the audio permission
```
