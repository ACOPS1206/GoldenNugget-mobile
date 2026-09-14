# PoC — on-device iOS 27 app-container restore

Private repo for an on-device proof-of-concept: **can a phone write a txt file
into a target app's container and restore it via `mobilebackup2` — without
triggering iOS 27's "safe state recovery" wipe?**

If the restore succeeds and the device does **not** erase, then the Pocket
Poster fork (posterboard wallpapers applied from an on-device app, no
computer) is viable — the wipe only fires for tweak plists delivered via
sparse restore.

## How it works

The app is a slim fork of [Nugget-Mobile](https://github.com/leminlimez/Nugget-Mobile)
(total, on-device Nugget). It reuses the same stack:

- **minimuxer** + **em_proxy** (via WireGuard) — an on-device usbmux clone
  listening on `127.0.0.1:27015`.
- **libimobiledevice** — `mobilebackup2` restore via `idevicebackup2`.

PoC flow (two stages):

1. **Stage 1 (backup/inject):** build a synthetic backup directory holding the
   target app's `AppDomain-<bundleID>/Documents/<file>` with the injected txt.
   The bundle is registered in `Manifest.plist`/`Info.plist` `Applications`
   dict (queried via the installation proxy), without which the restore
   daemon rejects the domain with `MBErrorDomain/205`.
2. **Stage 2 (restore):** `idevicebackup2 -n restore --no-reboot --system` —
   a normal `mobilebackup2` restore, **not** sparse restore.

Result: if the device does not wipe, app-only restores are safe on iOS 27.

## Build

GitHub Actions workflow (`.github/workflows/build.yml`) builds the `.ipa` on a
macOS runner with theos + procursus-action; grab `build/*.ipa` from the
artifact.

Local build (macOS):

```sh
brew install --cask theos
brew tap theos/theos && brew install theos   # or follow theos docs
export THEOS=$HOME/theos
git clone --recursive https://github.com/theos/sdks $THEOS/sdks
bash get_libraries.sh   # fetches minimuxer/em_proxy/libimobiledevice prebuilds
bash ipabuild.sh        # -> build/PoC.ipa
```

## Install / run

- `.mobiledevicepairing` file (from AltStore/SideStore) + the SideStore VPN /
  WireGuard running, exactly like Nugget-Mobile/SideStore.
- Open a pairing file in the app (or via the `.mobiledevicepairing` UTI).
- Default target is `com.apple.PosterBoard`; change bundle id / file name /
  contents as wanted.
- Tap **Run Backup → Inject → Restore**. Watch the log.
- Check the file landed in the app's `Documents`, then confirm the device did
  **not** wipe.

## Safety

- Experimental. A restore mistake can corrupt app data — test on a device you
  can afford to restore.
- This only restores app container data; it never touches system domains, so
  it should **not** trigger the iOS 27 security-recovery wipe (that is the
  hypothesis this PoC exists to test).

## License

Same as the underlying projects: followed from Nugget-Mobile (MIT) with
libimobiledevice (LGPL) and minimuxer (MIT) components. See their repos for
full texts.