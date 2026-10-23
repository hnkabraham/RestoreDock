# Device photo sources

RestoreDock prefers verified iPhone photographs from Apple's technical specifications and model-identification pages. IPSW Downloads supplies the model baseline and photos for iPads and iPhones without an Apple override.

- Apple photos: 67 iPhone model identifiers.
- IPSW.me fallback photos: 105 model identifiers (0 iPhone and 105 iPad).
- Baseline listings: https://ipsw.me/product/iPhone/ and https://ipsw.me/product/iPad/
- Manifest updated: 2026-10-23T05:54:27.989686+00:00
- Coverage: 67 iPhone identifiers and 105 iPad identifiers, using 99 unique image files.

`Resources/apple-iphone-photos.json` records reviewed Apple page/image URLs and exact model identifiers. Overrides apply only to identifiers present in the IPSW.me baseline; unlisted models retain their listing's photo. `manifest.json` maps identifiers to bundled files. `provenance.json` records each provider, source page, original image URL, retrieval time, and SHA-256, plus baseline provenance for Apple overrides.

Original source bytes, image formats, and dimensions are preserved. No cropping, resizing, retouching, recoloring, conversion, or generated imagery is applied. Identical content is deduplicated by SHA-256. These are third-party photographs; copyright and other rights remain with their respective owners.

Run `python3 Resources/update-device-photos.py` to refresh the IPSW.me baseline and apply Apple overrides. Use `--apple-only` to reuse the current baseline and unchanged bundled photos while applying the reviewed Apple overrides, without re-fetching every IPSW.me image. Removed overrides revert to their recorded fallback photo. Cache keys hash the full source URL.
