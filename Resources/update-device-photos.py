#!/usr/bin/env python3
"""Refresh exact model-to-photo mappings from IPSW.me's public product listings.

Downloads only images found on the two listing pages; never downloads firmware.
No cropping, scaling, color changes, retouching, or generated images are applied.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import tempfile
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen


SITE = "https://ipsw.me"
PAGES = {family: f"{SITE}/product/{family}/" for family in ("iPhone", "iPad")}


class DeviceParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.identifier = None
        self.name = None
        self.devices = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a":
            self.identifier = attrs.get("data-identifier")
            self.name = attrs.get("data-device-name")
        elif tag == "img" and self.identifier:
            url = urljoin(SITE, attrs["src"])
            parsed = urlparse(url)
            if parsed.scheme != "https" or parsed.hostname != "ipsw.me":
                raise ValueError(f"Unexpected image host: {url}")
            if not parsed.path.startswith("/images/devices/"):
                raise ValueError(f"Unexpected image path: {url}")
            self.devices[self.identifier] = {"name": self.name, "url": url}

    def handle_endtag(self, tag):
        if tag == "a":
            self.identifier = None
            self.name = None


def fetch(url):
    request = Request(url, headers={"User-Agent": "RestoreDock-PhotoUpdater/1.6"})
    with urlopen(request, timeout=30) as response:
        data = response.read(10 * 1024 * 1024 + 1)
    if len(data) > 10 * 1024 * 1024:
        raise ValueError(f"Photo or listing exceeds 10 MiB: {url}")
    return data


def atomic_write(path, data):
    """Keep caches and bundled images complete for concurrent readers."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--html-dir", type=Path, help="Reuse iphone.html and ipad.html from this directory")
    parser.add_argument("--cache-dir", type=Path, help="Keep original image bytes here for inspection")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "Sources/RestoreDock/Resources/DevicePhotos")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    devices = {}
    for family, page in PAGES.items():
        raw = (args.html_dir / f"{family.lower()}.html").read_bytes() if args.html_dir else fetch(page)
        listing = DeviceParser()
        listing.feed(raw.decode("utf-8"))
        if len(listing.devices) < 10:
            raise ValueError(f"Unexpectedly empty {family} listing; refusing to replace manifest")
        for identifier, item in listing.devices.items():
            item["listing"] = page
            devices[identifier] = item

    with tempfile.TemporaryDirectory(prefix="restoredock-photos-") as scratch:
        cache = args.cache_dir or Path(scratch)
        cache.mkdir(parents=True, exist_ok=True)

        def download(url):
            original = cache / Path(urlparse(url).path).name
            if not original.exists():
                atomic_write(original, fetch(url))
            data = original.read_bytes()
            if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
                extension = "webp"
            elif data.startswith(b"\x89PNG\r\n\x1a\n"):
                extension = "png"
            elif data.startswith(b"\xff\xd8\xff"):
                extension = "jpg"
            else:
                raise ValueError(f"Unexpected image format: {url}")
            digest = hashlib.sha256(data).hexdigest()
            filename = f"{digest[:24]}.{extension}"
            return url, filename, digest, data

        # Fetch a shared image URL once, regardless of how many models use it.
        with ThreadPoolExecutor(max_workers=4) as pool:
            downloaded = list(pool.map(download, sorted({item["url"] for item in devices.values()})))
        photos = {}
        written = set()
        for url, filename, digest, data in downloaded:
            if filename not in written:
                atomic_write(args.output / filename, data)
                written.add(filename)
            photos[url] = (filename, digest)
        results = []
        for identifier, details in devices.items():
            filename, digest = photos[details["url"]]
            results.append((identifier, filename, dict(details, sha256=digest)))

    manifest = dict(sorted((identifier, filename) for identifier, filename, _ in results))
    metadata = {
        "retrieved_at": datetime.now(timezone.utc).isoformat(),
        "listings": list(PAGES.values()),
        "transformation": "None. Original source bytes, original format, original dimensions.",
        "models": {identifier: dict(details, filename=filename) for identifier, filename, details in sorted(results)},
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.output / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
    counts = {family: sum(identifier.startswith(family) for identifier in manifest) for family in PAGES}
    source_text = f"""# Device photo sources

RestoreDock includes device product photographs from [IPSW Downloads](https://ipsw.me/).

- iPhone listings: https://ipsw.me/product/iPhone/
- iPad listings: https://ipsw.me/product/iPad/
- Retrieved: {metadata['retrieved_at']}
- Coverage: {counts['iPhone']} iPhone identifiers and {counts['iPad']} iPad identifiers, using {len(set(manifest.values()))} unique bundled image files.

Each identifier-to-photo association comes directly from the listing's `data-identifier` attribute and its corresponding `<img src>`; it is not inferred from model names. `manifest.json` maps each exact Apple model identifier to the bundled filename. `provenance.json` records the model name, listing URL, original image URL, and content SHA-256.

The original source image bytes, format, and dimensions are preserved. No conversion, cropping, resizing, retouching, recoloring, or generated imagery was applied. Identical content is deduplicated by SHA-256.

Run `python3 Resources/update-device-photos.py` from the source project on macOS to refresh the assets from the two live listing pages. The updater follows the image URLs that are actually present in the listings; the hash-based filenames on IPSW.me are not a predictable model-ID URL scheme.
"""
    (args.output / "SOURCES.md").write_text(source_text)
    print(f"Saved {len(manifest)} model mappings ({counts['iPhone']} iPhone, {counts['iPad']} iPad), {len(set(manifest.values()))} unique images.")


if __name__ == "__main__":
    main()
