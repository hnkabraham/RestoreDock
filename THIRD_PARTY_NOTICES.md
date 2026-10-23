# Third-party notices

## Device product photographs

RestoreDock bundles original product photographs from two sources:

- **Apple:** bundled iPhone photos are obtained directly from [Apple technical specifications](https://www.apple.com/iphone-17/specs/) and [Apple’s model identification pages](https://support.apple.com/en-us/108044), using explicit hardware-identifier mappings.
- **IPSW Downloads:** iPad photos use images linked from the [iPad catalog](https://ipsw.me/product/iPad/). The updater retains an IPSW.me baseline from the [iPhone catalog](https://ipsw.me/product/iPhone/) and iPad catalog for future or unmapped models. Not every bundled device photo is sourced directly from Apple.

Images are bundled for offline display. The app does not fetch product photos at runtime.

The photos are third-party material. Their copyright and other rights remain with the respective owners, including Apple where applicable. Their inclusion does not represent a transfer of ownership or an assertion that the images are covered by a license for RestoreDock’s code.

The asset collection preserves the original image bytes and formats. Its provenance records include the original image URLs, source pages, model mappings, and SHA-256 hashes:

- [Photo source notes](Sources/RestoreDock/Resources/DevicePhotos/SOURCES.md)
- [Per-image provenance](Sources/RestoreDock/Resources/DevicePhotos/provenance.json)
- [Model-to-photo mapping](Sources/RestoreDock/Resources/DevicePhotos/manifest.json)
- [Explicit Apple iPhone photo sources](Resources/apple-iphone-photos.json)

Repository screenshots also show these bundled product photographs where they appear in the app. The Storage screenshot is clearly marked as sample library data.

## Metadata and linked content

RestoreDock uses Apple’s public restore catalog and Software Lookup Service to discover public firmware releases. Firmware files are downloaded directly from Apple; the repository does not contain IPSW binaries.

IPSW.me supplies device names, public firmware histories, reported signing status, and metadata for historical downloads and imports. Apple Support release notes are loaded from Apple’s website inside the app; they are not authored by RestoreDock.

Source links and behavior are documented in the [user guide](docs/USER_GUIDE.md#sources-and-privacy).

## Names and affiliation

Apple, iPhone, iPad, iOS, iPadOS, macOS, and Apple Configurator are trademarks or product names of Apple Inc. Other names and marks belong to their respective owners. RestoreDock is independently developed and is not affiliated with, sponsored by, or endorsed by Apple or IPSW.me.

## Repository licensing

No source-code license is included in this release. The product photographs and trademarks are third-party material; this project does not offer a license to those assets.
