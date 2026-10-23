# Device photo sources

RestoreDock includes device product photographs from [IPSW Downloads](https://ipsw.me/).

- iPhone listings: https://ipsw.me/product/iPhone/
- iPad listings: https://ipsw.me/product/iPad/
- Retrieved: 2026-10-23T04:13:24.609161+00:00
- Coverage: 67 iPhone identifiers and 105 iPad identifiers, using 103 unique bundled image files.

Each identifier-to-photo association comes directly from the listing's `data-identifier` attribute and its corresponding `<img src>`; it is not inferred from model names. `manifest.json` maps each exact Apple model identifier to the bundled filename. `provenance.json` records the model name, listing URL, original image URL, and content SHA-256.

The original source image bytes, format, and dimensions are preserved. No conversion, cropping, resizing, retouching, recoloring, or generated imagery was applied. Identical content is deduplicated by SHA-256.

Run `python3 Resources/update-device-photos.py` from the source project on macOS to refresh the assets from the two live listing pages. The updater follows the image URLs that are actually present in the listings; the hash-based filenames on IPSW.me are not a predictable model-ID URL scheme.
