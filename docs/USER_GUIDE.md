# RestoreDock user guide

RestoreDock 1.6 keeps the latest public iPhone and iPad restore firmware ready for your workbench. This guide covers downloads, imports, storage, cleanup, and the limits of signing information.

[Back to the project README](../README.md)

## Start using it

1. Open **RestoreDock.app**. For everyday use, drag it to Applications first.
2. Open **Devices** and follow the iPhone and iPad models you restore. Search by model name or hardware identifier. **All supported iPhones & iPads** also includes newly discovered models automatically.
3. In **Settings**, choose a firmware folder. Fresh setups use Apple Configurator's firmware cache if it exists; otherwise they use Downloads/RestoreDock. Use **Create & use folder** to add the Configurator cache, or choose another folder, including an external drive. IPSWs are several GB each, so a large fleet needs substantial storage.
4. Click **Enable auto downloads**. The app checks every six hours by default; the interval is adjustable.
5. Enable **Open at login** if you want it to start after signing in. Closing the window keeps the app in the menu bar. Quitting stops checks and downloads until it opens again. Checks run while the Mac is awake; the app checks when due after waking.

To restore a connected device, select it in Finder, hold **Option**, and click **Restore iPhone** or **Restore iPad**, then choose the matching IPSW. Restoring erases the device. Finder and Apple perform the restore and authorize its firmware. A saved IPSW can become unusable for restoration after Apple stops signing it.

Click a model's photo or name in **Devices** to browse its public IPSW history. Select a release to see its version, build, date, size, and signing status, alongside Apple's original release-notes page. Apple groups notes by major OS version; the app jumps to the matching section when available. Older or newly introduced major versions without a known article use Apple's support search. IPSW history does not include updates distributed only over the air. Signing status comes from IPSW.me when the history loads and is not a guarantee that Apple will authorize a restore. Select a signed release and click **Download IPSW** to add that exact build to your queue. The app fetches fresh signing status from IPSW.me before queuing and requires an Apple HTTPS IPSW URL and valid SHA-1 checksum. Unsigned releases cannot be queued from history. This manual action does not change the models you follow or enable automatic downloads. A paused queue stays paused. Existing downloads are reused, and verified files offer **Show in Finder**. Signing can change after queuing or downloading; Apple still decides whether a restore is allowed.

## Import existing IPSWs

Open **Storage → Import existing IPSWs** (also available in Downloads). Choose individual files, one or more folders, or **Use Configurator cache** when that folder exists. Folder searches include subfolders, skipping hidden files, packages, and symbolic links. Files are registered in place; importing does not move, rename, copy, or delete the originals.

Click **Verify & import**. The app reads `BuildManifest.plist` from the archive to identify the release and supported iPhone/iPad models, retrieves matching IPSW.me metadata, and verifies the complete file against its expected size and SHA-1 checksum. Unknown, incomplete, changed, or unverifiable files are skipped with an explanation. Public signed and unsigned releases may be imported, but importing does not make unsigned firmware restorable. Metadata lookup requires internet access. No IPSW binary is downloaded during import.

Verified imports appear in your existing library and are reused for the same Apple download URL, avoiding another download. Files already registered, including physical aliases, are not duplicated. If that firmware is actively downloading or verifying, finish or pause the transfer and retry import. An unavailable file's drive needs to be reconnected for reuse. Folder changes do not move imported files.

Imports are protected from automatic deletion by default. The per-import option **Include these imports in automatic cleanup** requires confirmation; when enabled, those files become eligible for permanent deletion from their original folders if Automatic Cleanup is also enabled and every signing and file check passes. Already registered files keep their existing cleanup permission. Stopping import retains files already registered and leaves all source files untouched.

## Storage breakdown and cleanup preview

**Storage** shows actual current file sizes for completed library entries, grouped **By version** (version and build) or **By model**. Shared IPSWs and tracked hard-link aliases count once in the total. Model groups intentionally overlap when one file supports several models; do not add their subtotals. Version groups partition the files. Files in progress are excluded.

Missing or inaccessible files are reported and excluded from the total. Changed files show their current size and are excluded from the cleanup preview. **Refresh sizes** checks the filesystem again; the lightweight size check is not a fresh checksum verification. Sizes are logical file bytes; compression, APFS clones, and untracked hard links can make actual disk space differ.

**Preview cleanup** checks fresh signing data and lists eligible files with their estimated size, along with reasons for keeping other files. It works with Automatic Cleanup off, does not delete files or enable deletion, and expires after its signing evidence ages out. Library changes invalidate the preview. Actual automatic cleanup performs fresh eligibility checks and full checksum verification; the preview is informational and never authorizes deletion. Imported files remain excluded unless explicitly opted in during import.

## Automatic cleanup

In **Settings → Automatic Cleanup**, enable **Automatically delete unsigned IPSWs** and confirm the explanation. It is off by default, including after upgrading. Enabling it runs a check immediately, then checks at your configured firmware-check interval while the app is open and the Mac is awake. **Check & clean now** runs another check on demand. Automatic downloads do not need to be enabled.

Cleanup permanently deletes eligible files, bypassing Trash so they no longer occupy the library's disk space. It cannot be undone. Only completed downloads and imports explicitly allowed for cleanup are considered; cleanup never scans folders for arbitrary IPSWs. It checks fresh IPSW.me signing metadata for the exact version, build, Apple URL, and every model linked to a shared download. Any signed model, unknown/missing/conflicting status, stale response, or network failure keeps the file. This uses IPSW.me's reported signing status, not a direct Apple TSS request.

Before removal, the app checks the recorded path and re-verifies the file's checksum. Changed files, unavailable drives, partial/active downloads, and files that fail verification are kept. Turning cleanup off cancels work that has not already removed a file. A cleanup report shows the last check, files removed, total bytes removed, and any skipped files or errors.

Successfully removed images are remembered so a delayed Apple catalog cannot automatically download the same image again. An explicit manual download can request the file again, subject to the history screen's current signing check. Existing files outside the app's completed-download records remain yours to manage.

## Apple Configurator folder

The preset uses exactly:

```text
~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware
```

On a fresh setup, this becomes the default only when it already exists as a directory. Existing saved destinations are preserved. If the folder is absent, **Settings → Storage → Create & use folder** creates it and selects it. If present, **Use Configurator folder** selects it. Permission errors are shown without changing the selected destination.

This places completed IPSWs in that folder; it does not register files in a Configurator database. Use Storage’s import flow to recognize existing cached IPSWs. Automatic cache recognition has not been verified. Configurator controls its cache and may remove cached files. Apple also supports [dragging an IPSW onto a selected device in Configurator](https://support.apple.com/guide/apple-configurator-mac/update-devices-cad789a3f0bd/mac). Started and completed downloads keep their original locations when the destination changes.

## What it does

- Discovers current public releases and supported hardware dynamically from Apple. This includes older hardware still listed for public security releases.
- Lets you follow individual models or all supported models. One IPSW shared by several models is downloaded once.
- Downloads firmware only over HTTPS from Apple hosts, including validation of redirects.
- Verifies the file size when known, ZIP header, and metadata's SHA-1 checksum before publishing a completed `.ipsw`. Automatic latest-release checksums come from Apple's catalog; historical checksums come from IPSW.me metadata. All firmware binaries download directly from Apple.
- Persists the queue and selections; supports pause, resume, retry, and optional completion notifications.
- Keeps a configurable free-space reserve. The macOS temporary volume also needs room for a transfer before it reaches an external library folder.
- Retains older files by default. Optional automatic cleanup permanently removes verified managed downloads reported unsigned for all linked models. It never overwrites an unknown file.

Turning off automation stops new automatic queue additions. Use **Pause queue** to stop existing transfers. Unfollowing a model leaves its existing queue entries in place. Removing an entry from the queue leaves any completed file alone. Changing the library folder applies to downloads that have not started; started and completed downloads retain their original location.

Partial downloads resume when macOS provides usable resume data. After a force quit or invalid resume data, an individual file may restart. Temporary network failures are retried with bounded backoff; permanent failures remain visible for manual retry. Catalog failures preserve the last successful catalog. No Apple ID, device access, restore privileges, or paid service is needed.

## Sources and privacy

Apple supplies firmware metadata and binaries:

- [Apple restore catalog](https://itunes.apple.com/check/version)
- [Apple Software Lookup Service](https://gdmf.apple.com/v2/pmv), described in [Apple's deployment documentation](https://developer.apple.com/documentation/devicemanagement/deploying-software-updates-using-declarative-management)
- [IPSW.me device metadata](https://api.ipsw.me/v4/devices) supplies optional human-readable model names. If it is unavailable, hardware identifiers remain usable.
- [IPSW.me's API](https://ipswdownloads.docs.apiary.io/) supplies per-model public IPSW history, signing status, download URLs, sizes, and checksums when you open a model. Signing status is fetched again before a historical release is queued. Apple's own Support pages provide the embedded release notes.
- Bundled iPhone photos use original images from [Apple technical specifications](https://www.apple.com/iphone-17/specs/) and [Apple’s model identification pages](https://support.apple.com/en-us/108044), through explicit hardware-identifier mappings. iPad photos come from [IPSW.me's iPad catalog](https://ipsw.me/product/iPad/). Future or unmapped models can use the IPSW.me baseline until an explicit Apple photo mapping is added. Not every device photo is sourced directly from Apple. The original bytes and formats are preserved; photos are bundled for offline display and are not fetched at runtime. Exact source URLs and model mappings are included alongside the assets. See [third-party notices](../THIRD_PARTY_NOTICES.md). Future models without a bundled photo use a device symbol until the collection is refreshed.

Automatic discovery fetches the same complete metadata catalogs, then requests the Apple files you select. Opening a model's history, checking a historical download, importing an IPSW, previewing cleanup, or running enabled cleanup sends the relevant model identifiers to IPSW.me. Viewing release notes loads the corresponding Apple Support page in an embedded browser using an ephemeral website data store. The app has no analytics, accounts, or cloud synchronization. Firmware defaults to the existing Configurator cache or `~/Downloads/RestoreDock/` as described above.

### Compatibility with earlier versions

RestoreDock was previously called Firmware Shelf. To preserve existing libraries and settings, it retains the bundle identifier `com.firmwareshelf.mac` and stores settings, cached catalog, queue metadata, and resume data in `~/Library/Application Support/FirmwareShelf/`. Existing saved firmware destinations, including `~/Downloads/Firmware Shelf/`, remain unchanged. When no saved destination or Configurator cache is available, an existing legacy Downloads folder is reused before creating `~/Downloads/RestoreDock/`. The new name does not require moving your files.

Public release availability is not a live Apple TSS signing check. Apple may publish its two catalogs at different times; the app displays catalog notes and retries on the next refresh.

## Requirements and distribution

- macOS 14 Sonoma or newer.
- The packaged app is universal: Apple silicon and Intel.
- This is a locally built, ad-hoc signed app, not a Developer ID notarized release. Organizations distributing it to other Macs should sign and notarize it with their own Apple Developer credentials. No credentials are included or required to build locally.

## Build from source

Install Xcode with the macOS SDK and Swift 5.9 or later, then run from the repository root:

```sh
./build-app.sh
```

The script compiles both architectures, creates `dist/RestoreDock.app`, adds the icon, signs locally, and creates `dist/RestoreDock-macOS.zip`. You can supply a different output directory as its first argument.

Open `Package.swift` in Xcode to inspect or edit the source. Use the packaged app for the complete experience, since menu bar integration, notifications, and Open at Login rely on a proper app bundle. Developer ID signing and notarization are deliberately left to the app owner.

## Tests

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift test --disable-sandbox --build-system native --cache-path "$PWD/.build/cache"
```

To include a metadata-only check against the live Apple catalogs:

```sh
RESTOREDOCK_LIVE_TEST=1 swift test --disable-sandbox --build-system native --cache-path "$PWD/.build/cache"
```

Tests cover public-release filtering, new-model discovery, numeric version ordering, Apple URL restrictions, deduplication, persistence, checksum verification, filename collision handling, storage guards, release-history parsing, signed-release download eligibility, historical queue persistence and deduplication, conservative cleanup decisions, verified file removal, automatic re-download suppression, Configurator folder selection and creation, verified imports, in-place registration, physical-file deduplication, storage measurement, and cleanup previews. Folder tests use temporary directories. Live metadata testing downloads no firmware binaries. A full multi-GB IPSW transfer has not been run as part of this build.

## Source layout

- `Sources/FirmwareCore/`: Apple catalog parser, download queue, validation, and persistence.
- `Sources/RestoreDock/`: native window, model picker, menu bar, settings, and notifications.
- `Tests/FirmwareCoreTests/`: deterministic and opt-in live tests.
- `Resources/`: app metadata, procedural icon source, and `update-device-photos.py` to refresh the copied photo collection before rebuilding.
- `Sources/RestoreDock/Resources/DevicePhotos/`: bundled product photos, model mapping, and source attribution.
- `build-app.sh`: reproducible universal app packaging.

## Refreshing product photos

Run the photo updater from the repository root before rebuilding the app. Apple photo overrides are defined in [`Resources/apple-iphone-photos.json`](../Resources/apple-iphone-photos.json), with exact Apple hardware identifiers and original source URLs. They override the IPSW.me baseline only for their listed models; the updater does not guess images from model names.

To refresh only the Apple photos while retaining the bundled baseline for other devices:

```sh
python3 Resources/update-device-photos.py --apple-only
```

To refresh the IPSW.me baseline and then apply the Apple overrides:

```sh
python3 Resources/update-device-photos.py
```

The updater saves original image bytes and formats, deduplicates identical content, and updates the bundled manifest, provenance, and source notes. Rebuild the app to include the refreshed collection. This is a maintainer step, not a runtime network request made when a user opens Devices.
