# ChargeLmt

[简体中文](README.md) | English  

ChargeLmt is a menu bar macOS application designed to set battery charge limits (both upper and lower thresholds). It also features single-charge calibration (charge to 100% once), discharge to the upper limit, launch at login, and Sparkle automatic updates.  
The reason for reinventing this wheel is that [Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit) has ceased maintenance and does not work properly on macOS versions after macOS 15, while AlDente is paid and bloated, which I strongly dislike.  

## Compatibility

Mac computers with Apple silicon running `macOS Tahoe 26.4` and later natively support customizing MacBook battery charge limits; therefore, this software is only intended for Macs running earlier macOS versions or Macs powered by x86 (Intel) processors.  
Official Apple Guide: [About Optimized Battery Charging and Charge Limit on Mac](https://support.apple.com/en-us/102338)  

## Implementation Details

- Built as a menu bar application (`LSUIElement`), using Sparkle for automatic updates.  
- Launch at login is handled by a dedicated helper.  
- Charging control is managed by a privileged helper writing to the SMC, selecting backends such as Legacy Intel, Golden Gate Apple Silicon, or Tahoe based on the hardware model.  
- Charge range control operates as an application-level hysteresis state machine: upon launch or when plugging in the adapter, if the battery is within the range, the lower limit is written to avoid charging; when the battery drops below the lower limit, the upper limit is written to begin charging until the upper limit is reached; upon reaching the upper limit, the lower limit is written to halt charging, avoiding repeated micro-cycles (sailing mode) until the battery level naturally drops back to the lower limit.  

On Apple Silicon, this project prioritizes Golden Gate `bfD0`/`bfE0`/`bfF0` threshold keys, falling back to `CHTE`/`CH0C`/`CH0B` on older Apple Silicon models; on Intel, it prioritizes `CH0B`/`CH0C` charging switches, falling back to `BCLM`/`BFCL` on legacy models. For models supporting hardware charge thresholds (such as Intel BCLM or Golden Gate), the upper limit is written to the controller to begin charging when below the lower limit, and the lower limit is written back once the upper limit is reached to stop charging; switch-based models toggle charging on below the lower limit and off at the upper limit. `CHIE`/`CH0J` are used to temporarily disable adapter output for discharging; models lacking these keys will indicate that forced discharge is unsupported. An idle-sleep assertion is held during charging or discharging to prevent the system from bypassing threshold control during sleep.  

The Golden Gate write sequence is: `bfF0=0`, `bfD0=upper_limit<<24`, `bfE0=(upper_limit-1)<<24`, `bfF0=2`. When starting to charge below the lower limit, the user's upper limit is written; upon reaching the upper limit, the user's lower limit is written to prevent repeated micro-cycles. The Xcode Debug build uses a local legacy daemon to bypass development code-signing profile restrictions; production releases use `SMAppService`.  

## Build

```bash
xcodebuild -project ChargeLmt.xcodeproj -scheme ChargeLmt -configuration Release build
```

Sparkle is integrated via Swift Package Manager and locked in `Package.resolved`, so binary frameworks do not need to be committed. Dependencies are resolved automatically during the initial build. After building, the root daemon can be installed via the Settings window; macOS will require approval in System Settings.  

## Automatic Update Release Configuration

Before releasing, configure `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` via build settings; `SUFeedURL` and `SUPublicEDKey` in `Support/App-Info.plist` will be expanded at build time. Automatic checking and installation are handled by Sparkle.  
  
EdDSA keys can be generated using `bin/generate_keys --account chargelmt` from the official Sparkle distribution; `Scripts/release.sh` calls `generate_appcast --account chargelmt` to generate signatures.  
By default, this project builds a universal binary, so a single appcast pointing to the universal zip archive is sufficient. If separate arm64 / x86_64 packages are split in the future, distinct appcasts and download URLs must be provided for each architecture.  

## Security Notes

Before official distribution, the app should be signed with a stable Developer ID and notarized. The root daemon only exposes threshold and mode commands and does not provide arbitrary command execution interfaces. Production builds can further validate XPC clients based on Team ID and Bundle ID.  

## Acknowledgements

The SMC user-space invocation structures and Apple Silicon power keys reference Marvin Häuser's [Battery Toolkit](https://github.com/mhaeuser/Battery-Toolkit) (BSD-3-Clause). Intel `BCLM`/`BFCL` behavior references Zack Elia's [bclm](https://github.com/zachelia/bclm) (MIT). Automatic updates use [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT). Full license texts for each component can be found in their respective upstream repositories. This project is licensed under MIT, see `LICENSE`.  
