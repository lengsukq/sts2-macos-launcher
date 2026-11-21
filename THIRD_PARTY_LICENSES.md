# Third-Party Licenses & Notices

This launcher contains no *Slay the Spire 2* commercial game assets, game assemblies (`sts2.dll`), DRM/authentication bypasses, or user saves. Users supply their own local Windows game files and are solely responsible for ensuring lawful ownership and licensing compliance with the relevant platform and game EULA.

Public releases built via `scripts/bundle-mit-release.sh` embed **only** the MIT-licensed core runtime components listed in Section 1 below. Restricted or proprietary third-party binaries in Section 2 are never committed to this Git repository and are never embedded in public release archives; instead, end users fetch them directly from official upstream sources to their local Application Support directory.

---

## 1. MIT-Licensed Components (Eligible for Public MIT Release Bundle)

### Godot Engine (`4.5.1-stable` Mono Export Template & `GodotSharp`)
- **License**: MIT License
- **Copyright**: (c) 2014-present Godot Engine contributors, (c) 2007-2014 Juan Linietsky, Ariel Manzur
- **Source**: https://github.com/godotengine/godot

### .NET 9 Runtime (`osx-arm64` CoreCLR & BCL) & `System.IO.Hashing`
- **License**: MIT License
- **Copyright**: (c) .NET Foundation and Contributors
- **Source**: https://github.com/dotnet/runtime

### Harmony (`Lib.Harmony` 2.4.2, compile-time reference only)
- **License**: MIT License
- **Copyright**: (c) Andreas Pardeike
- **Source**: https://github.com/pardeike/Harmony

---

## 2. Upstream Third-Party Components (User-Side Direct Fetch Only — Never Embedded in Public Releases)

### `fmod-gdextension` (`6.1.0-4.5.0`)
- **License**: MIT License (GDExtension wrapper)
- **Source**: https://github.com/utopia-rise/fmod-gdextension

### FMOD Engine (`2.03.06`)
- **License**: Proprietary (FMOD EULA)
- **Copyright**: (c) Firelight Technologies Pty Ltd
- **Website**: https://www.fmod.com
- **Attribution**: Made using FMOD Studio by Firelight Technologies Pty Ltd.
- **Note**: FMOD binaries are never committed to Git or embedded in `scripts/bundle-mit-release.sh`. End users fetch them directly from upstream at runtime under Firelight Technologies' licensing terms.

### Spine Runtimes (`spine-godot` `4.2`)
- **License**: Spine Runtimes License Agreement (https://esotericsoftware.com/spine-runtimes-license)
- **Copyright**: (c) 2013-present, Esoteric Software LLC
- **Source**: https://github.com/EsotericSoftware/spine-runtimes
- **Note**: Spine binaries are never committed to Git or embedded in `scripts/bundle-mit-release.sh`. End users fetch them directly from Esoteric Software's official release archive for use with licensed Spine-powered software.

### Steamworks SDK (`libsteam_api.dylib`)
- **License**: Proprietary (Valve Steamworks SDK License)
- **Copyright**: (c) Valve Corporation
- **Note**: No Steamworks binaries are bundled, downloaded, or distributed by this project. Users who wish to integrate with a local Steam client may optionally point the launcher to their own legitimate copy of `libsteam_api.dylib`.
