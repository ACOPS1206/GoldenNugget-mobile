<div align="center">  
   
![GoldenNugget Mobile](layout/Applications/GoldenNuggetMobile.app/Logo@2x.png)  
   
# GoldenNugget Mobile  
   
**Unlock your device's full potential — without a PC.**  
   
A port of [GoldenNugget](https://github.com/awesomenull-dev/GoldenNugget) to iOS. The  
tweaks, the daemon switches and the backup→tweak→restore pipeline are the same; the GUI  
is the phone's, and there is no Python on the other end.  
   
Customize your device, disable pesky daemons, browse and pull your media, and more!  
   
> [!NOTE]  
> Please back up your data before using this project! GoldenNugget may cause unforeseen  
> problems, so it is better to be safe than sorry. We are not responsible for any damage  
> done to your device.  
   
> [!WARNING]  
**I am not responsible for any data loss or bootloops; if something goes off, it is your fault.**  
   
## Discord server  
   
Wanted support? Join our [Discord Server][server].  
   
## Features  
   
### In this build  
   
<details>  
<summary><b>Tweaks</b> — 133, generated from the desktop registry</summary>  
   
- **Liquid Glass** (98) — disable and tune the iOS 26+ visual system  
- **SpringBoard Options** (17) — lock screen footnote, auto-lock time, respring and  
  screen-dimming behaviour, low-battery alerts, Dynamic Island in screenshots, Stage  
  Manager AirPlay, the red/green authentication line, floating tab bar on iPad  
- **Internal Options** (18) — build version in the status bar, force RTL, hidden icons on  
  the Home Screen, Metal HUD, the App Store debug gesture, notes debug mode, show touches,  
  paste behaviour and notifications  
   
Tweaks that do not apply to your device or iOS version are not shown at all, rather than  
shown disabled.  
   
</details>  
   
<details>  
<summary><b>Disable Daemons</b> — 40 groups</summary>  
   
One switch per group, over the launchd `disabled.plist`, plus a Screen Time agent  
nullify. Includes OTA, UsageTrackingAgent, Game Center, ATWAKEUP, Tips, VPN icon, Chinese  
WLAN service, HealthKit, AirPrint, AssistiveTouch, iCloud, Internet Tethering, PassBook,  
Spotlight, Shazam, CrashReports, Diagnostics, Feedback and more — the full list is  
generated from the desktop app's group tables, so it tracks upstream.  
   
</details>  
   
<details>  
<summary><b>Files</b></summary>  
   
- A native browser over the device's own AFC service: navigate, sort, Quick Look,  
  delete, upload  
- Media backup pull, with the store reported by manifest rather than a directory walk  
   
</details>  
   
<details>  
<summary><b>Reset Tweaks</b></summary>  
   
Put a page back to stock on the device — Springboard, Internal or Daemons. Same file sets  
as the desktop reset; see [`docs/tweak-port.md`](docs/tweak-port.md) §2.4 for what is  
written on each iOS branch and why a nulled file is an empty plist on iOS 27 rather than  
0 bytes.  
   
</details>  
   
<details>  
<summary><b>Presets, Skip Setup, diagnostics</summary>  
   
- Import `autosave.json` or any exported preset; each entry is reported as applied,  
  unported, incompatible or unknown  
- Skip Setup (off by default) writes the CloudConfigurationDetails and purplebuddy files  
- A preflight that refuses to run against an encrypted local backup, because the prune  
  and inject path needs a plaintext manifest  
   
</details>  
   
## Requirements  
   
An iPhone or iPad on iOS 26.0 or newer, and a way to sideload:  
   
1. Grab the latest release.  
2. Install **localdevvpn** from the App Store (it carries the pairing record the app needs).  
3. Disable **Find My** on the device.  
4. Sideload with Livecontainer, AltStore/SideStore, ILoader or paid certificate   
> [!NOTE]  
> If you using Feather or LiveContainer **ENABLE FILE PICKER FIX** 
    
   
## Building    
   
xtool (works on Linux and macOS, driven by `xtool.yml`):  
   
```sh  
scripts/build-ipa-xtool.sh     # -> xtool/GoldenNuggetMobile.ipa  
```  
   
Xcode (macOS only, driven by `GoldenNuggetMobile.xcodeproj`):  
   
```sh  
scripts/build-ipa.sh Release      # -> build/GoldenNuggetMobile.ipa (unsigned)  
```  
   
## Contributors  
   
<div align="center">  
   
**Thanks everyone who contributes to this project!** 🎉  
   
<a href="https://github.com/GoldenNugget-Team/GoldenNugget-mobile/graphs/contributors">  
  <img src="https://contrib.rocks/image?repo=GoldenNugget-Team/GoldenNugget-mobile" alt="Contributors" />  
</a>  
   
Want to see your name here? Open a [Pull Request](https://github.com/GoldenNugget-Team/GoldenNugget-mobile/pulls)!  
   
</div>  
   
## Star History  
   
<a href="https://www.star-history.com/?type=date&repos=GoldenNugget-Team%2FGoldenNugget-mobile">  
  <picture>  
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=GoldenNugget-Team/GoldenNugget-mobile&type=date&theme=dark&legend=top-left" />  
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=GoldenNugget-Team/GoldenNugget-mobile&type=date" />  
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=GoldenNugget-Team/GoldenNugget-mobile&type=date" />  
  </picture>  
</a>  
   
<div align="center">  
<br>We think you can star this repo if you think this is a good project.</br>  
</div>  
   
> [!NOTE]  
> ## Mobilegestalt  
> Don't even ask me for it. It will be NEVER implemented again.  
   
## Credits  
   
This is a port. The tweak registry, the daemon groups, the restore pipeline and the GUI  
design all come from the desktop project, and it in turn comes from [GoldenNugget][GoldenNugget].  
   
- [GoldenNugget][GoldenNugget] — the desktop app this is ported from  
- Translations crowdsourced using the [gNugget-i18n repository][i18n]  
- [LEGACY] Old translations were crowdsourced using [Nugget POEditor][POEditorJoin].  
  Thank you everyone who assisted in the translation effort!  
- [LeminLimez] for creating Nugget.  
- [Wind0ws11Aero] for helping with development a lot.  
- [0xjonhnnydev] for [AirLift]  
- [PosterRestore][PosterRestoreDiscord] for their help with PosterBoard  
  - Special thanks to [dootskyre][dootskyreX], [Middo][MiddoX], [dulark][dularkGitHub], forcequitOS, and pingubow for their work on nugget. It would not have been possible without them!  
  - Thanks to [Snoolie for aar handling][python-aar-stuffGitHub]!  
- [iTechExpert][iTechExpertTwitter] for various Springboard/Internal Options  
- [Mikasa-san][Mikasa-sanGitHub] for [Quiet Daemon][QuietDaemonGitHub]  
- [pymobiledevice3][pymobiledevice3GitHub] for restoring and device algorithms.  
- [PySide6][PySide6Doc] for the desktop GUI library.  
   
[Nugget]: https://github.com/leminlimez/Nugget  
[GoldenNugget]: https://github.com/awesomenull-dev/GoldenNugget  
[i18n]: https://github.com/awesomenull-dev/gNugget-i18n  
[LeminLimez]: https://github.com/leminlimez  
[Wind0ws11Aero]: https://github.com/Wind0ws11Aero  
[POEditorJoin]: https://poeditor.com/join/project/UTqpVSE2UD  
[PosterRestoreDiscord]: https://discord.gg/gWtzTVhMvh  
[dootskyreX]: https://x.com/dootskyre  
[MiddoX]: https://x.com/MWRevamped  
[dularkGitHub]: https://github.com/dularkian  
[Mikasa-sanGitHub]: https://github.com/Mikasa-san  
[QuietDaemonGitHub]: https://github.com/Mikasa-san/QuietDaemon  
[pymobiledevice3GitHub]: https://github.com/doronz88/pymobiledevice3  
[iTechExpertTwitter]: https://twitter.com/iTechExpert21  
[PySide6Doc]: https://doc.qt.io/qtforpython-6/  
[python-aar-stuffGitHub]: https://github.com/0xilis/python-aar-stuff  
[server]: https://discord.gg/Rm6r4zeE3y  
[0xjonhnnydev]: https://github.com/0xjohnnydev  
[AirLift]: https://github.com/0xjohnnydev/airlift  
