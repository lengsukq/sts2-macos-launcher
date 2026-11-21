# Third-Party Licenses & Notices

This launcher contains no *Slay the Spire 2* commercial game assets, game assemblies (`sts2.dll`), or user saves. Users must supply their own legally owned Windows game files.

When built in standalone distribution mode (`scripts/bundle-standalone.sh`), the application bundle embeds the following third-party runtime components:

## Godot Engine (4.5.1-stable Mono Export Template & GodotSharp)
- **License**: MIT License
- **Copyright**: (c) 2014-present Godot Engine contributors, (c) 2007-2014 Juan Linietsky, Ariel Manzur
- **Source**: https://github.com/godotengine/godot

## .NET 9 Runtime (osx-arm64 CoreCLR & BCL) & System.IO.Hashing
- **License**: MIT License
- **Copyright**: (c) .NET Foundation and Contributors
- **Source**: https://github.com/dotnet/runtime

## fmod-gdextension (6.1.0-4.5.0)
- **License**: MIT License (GDExtension wrapper)
- **Source**: https://github.com/utopia-rise/fmod-gdextension

## FMOD Engine (2.03.06)
- **License**: Proprietary (FMOD EULA)
- **Copyright**: (c) Firelight Technologies Pty Ltd
- **Website**: https://www.fmod.com
- **Attribution**: Made using FMOD Studio by Firelight Technologies Pty Ltd.
- **Note**: FMOD binaries are never committed to this Git repository and are subject to Firelight Technologies' licensing terms.

## Spine Runtimes (`spine-godot` 4.2)
- **License**: Spine Runtimes License Agreement (https://esotericsoftware.com/spine-runtimes-license)
- **Copyright**: (c) 2013-present, Esoteric Software LLC
- **Source**: https://github.com/EsotericSoftware/spine-runtimes
- **Note**: Spine binaries are never committed to this Git repository and may only be used with licensed Spine-powered software.

## Steamworks SDK (`libsteam_api.dylib`)
- **License**: Proprietary (Valve Steamworks SDK License)
- **Copyright**: (c) Valve Corporation
- **Note**: No Steamworks binaries are bundled or distributed in this repository. Users must provide their own legitimate copy from an official Steam installation or SDK.
