#!/usr/bin/env python3
"""Refresh original device photos, preferring verified Apple iPhone overrides.

IPSW.me supplies the model baseline and fallback photos. No firmware is downloaded
and no images are cropped, resized, recolored, retouched, or generated.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import tempfile
from urllib.parse import urljoin, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

SITE = "https://ipsw.me"
PAGES = {family: f"{SITE}/product/{family}/" for family in ("iPhone", "iPad")}
APPLE_HOSTS = {"www.apple.com", "support.apple.com", "cdn.apple.com",
               "km.support.apple.com", "cdsassets.apple.com", "images.apple.com"}
APPLE_PAGE_HOSTS = {"www.apple.com", "support.apple.com"}
ASSET_NAME = re.compile(r"[0-9a-f]{24}\.(?:png|jpg|webp)\Z")
LIMIT = 10 * 1024 * 1024
ROOT = Path(__file__).resolve().parents[1]


def checked_url(url, hosts):
    if not isinstance(url, str):
        raise ValueError("Source URLs must be strings")
    parsed = urlparse(url)
    if (parsed.scheme != "https" or parsed.hostname not in hosts or parsed.username
            or parsed.password or parsed.port not in (None, 443) or not parsed.path):
        raise ValueError(f"Unapproved source URL: {url}")
    return url


class SafeRedirect(HTTPRedirectHandler):
    def __init__(self, hosts):
        self.hosts = hosts

    def redirect_request(self, request, response, code, message, headers, newurl):
        checked_url(newurl, self.hosts)
        return super().redirect_request(request, response, code, message, headers, newurl)


def fetch(url, hosts=frozenset({"ipsw.me"})):
    checked_url(url, hosts)
    request = Request(url, headers={"User-Agent": "RestoreDock-PhotoUpdater/1.6"})
    with build_opener(SafeRedirect(hosts)).open(request, timeout=30) as response:
        checked_url(response.geturl(), hosts)
        data = response.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError(f"Photo or listing exceeds 10 MiB: {url}")
    return data


class DeviceParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.identifier = self.name = None
        self.devices = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a":
            self.identifier, self.name = attrs.get("data-identifier"), attrs.get("data-device-name")
        elif tag == "img" and self.identifier:
            url = checked_url(urljoin(SITE, attrs["src"]), {"ipsw.me"})
            if not urlparse(url).path.startswith("/images/devices/"):
                raise ValueError(f"Unexpected image path: {url}")
            self.devices[self.identifier] = {"name": self.name, "url": url}

    def handle_endtag(self, tag):
        if tag == "a":
            self.identifier = self.name = None


def atomic_write(path, data):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def image_record(data, url):
    if len(data) > LIMIT:
        raise ValueError(f"Image exceeds 10 MiB: {url}")
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        extension = "webp"
    elif data.startswith(b"\x89PNG\r\n\x1a\n"):
        extension = "png"
    elif data.startswith(b"\xff\xd8\xff"):
        extension = "jpg"
    else:
        raise ValueError(f"Unexpected image format: {url}")
    digest = hashlib.sha256(data).hexdigest()
    return f"{digest[:24]}.{extension}", digest, data


def existing_assets(output, required):
    manifest_file, provenance_file = output / "manifest.json", output / "provenance.json"
    manifest = json.loads(manifest_file.read_text()) if manifest_file.exists() else {}
    if not isinstance(manifest, dict) or not all(isinstance(v, str) for v in manifest.values()):
        raise ValueError("Invalid existing photo manifest")
    if not required:
        return manifest, {}, {}
    metadata = json.loads(provenance_file.read_text())
    models, photos = metadata["models"], {}
    if not manifest or set(models) != set(manifest):
        raise ValueError("Apple-only refresh requires a complete manifest and provenance")
    for identifier, filename in manifest.items():
        details = models[identifier]
        path = output / filename
        if not ASSET_NAME.fullmatch(filename) or path.is_symlink() or details["filename"] != filename:
            raise ValueError(f"Unsafe or inconsistent bundled image: {identifier}")
        record = image_record(path.read_bytes(), details["url"])
        if record[0] != filename or record[1] != details["sha256"]:
            raise ValueError(f"Bundled image checksum mismatch: {identifier}")
        details.setdefault("retrieved_at", metadata.get("retrieved_at"))
        photos[details["url"]] = record
    return manifest, models, photos


def baseline(args, models):
    if args.apple_only:
        devices = {}
        for identifier, details in models.items():
            original = details.get("fallback", details)
            if urlparse(original["url"]).hostname != "ipsw.me":
                raise ValueError(f"Missing IPSW.me baseline provenance: {identifier}")
            devices[identifier] = {key: original[key] for key in ("name", "url", "listing")}
        return devices
    devices = {}
    for family, page in PAGES.items():
        raw = (args.html_dir / f"{family.lower()}.html").read_bytes() if args.html_dir else fetch(page)
        listing = DeviceParser()
        listing.feed(raw.decode("utf-8"))
        if len(listing.devices) < 10:
            raise ValueError(f"Unexpectedly empty {family} listing; refusing to replace manifest")
        devices.update({identifier: dict(item, listing=page) for identifier, item in listing.devices.items()})
    return devices


def apply_overrides(devices, overrides):
    if not isinstance(overrides, list):
        raise ValueError("Apple overrides must be a JSON array")
    for details in devices.values():
        details.update(provider="IPSW.me", source="IPSW Downloads product listing", page=details["listing"])
    seen = set()
    for entry in overrides:
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str) or not entry["name"].strip():
            raise ValueError("Each Apple override needs a model name")
        identifiers = entry.get("identifiers")
        if not isinstance(identifiers, list) or not identifiers:
            raise ValueError("Each Apple override needs exact model identifiers")
        page = checked_url(entry.get("page_url"), APPLE_PAGE_HOSTS)
        url = checked_url(entry.get("image_url"), APPLE_HOSTS)
        optional = {}
        if "stylesheet_url" in entry:
            optional["stylesheet_url"] = checked_url(entry["stylesheet_url"], APPLE_HOSTS)
        if "note" in entry:
            if not isinstance(entry["note"], str):
                raise ValueError("Apple override notes must be strings")
            optional["note"] = entry["note"]
        for identifier in identifiers:
            if (not isinstance(identifier, str) or not re.fullmatch(r"iPhone\d+,\d+", identifier)
                    or identifier not in devices or identifier in seen):
                raise ValueError(f"Unknown, duplicate, or non-iPhone override identifier: {identifier}")
            seen.add(identifier)
            fallback = {key: devices[identifier][key] for key in ("name", "url", "listing")}
            devices[identifier] = dict(name=entry["name"], url=url, provider="Apple",
                                      source="Apple product documentation", page=page,
                                      listing=fallback["listing"], fallback=fallback, **optional)


def source_notes(metadata, manifest):
    models = metadata["models"]
    apple = sum(item["provider"] == "Apple" for item in models.values())
    counts = {family: sum(identifier.startswith(family) for identifier in manifest) for family in PAGES}
    return f"""# Device photo sources

RestoreDock prefers verified iPhone photographs from Apple's technical specifications and model-identification pages. IPSW Downloads supplies the model baseline and photos for iPads and iPhones without an Apple override.

- Apple photos: {apple} iPhone model identifiers.
- IPSW.me fallback photos: {len(models) - apple} model identifiers ({counts['iPhone'] - apple} iPhone and {counts['iPad']} iPad).
- Baseline listings: https://ipsw.me/product/iPhone/ and https://ipsw.me/product/iPad/
- Manifest updated: {metadata['updated_at']}
- Coverage: {counts['iPhone']} iPhone identifiers and {counts['iPad']} iPad identifiers, using {len(set(manifest.values()))} unique image files.

`Resources/apple-iphone-photos.json` records reviewed Apple page/image URLs and exact model identifiers. Overrides apply only to identifiers present in the IPSW.me baseline; unlisted models retain their listing's photo. `manifest.json` maps identifiers to bundled files. `provenance.json` records each provider, source page, original image URL, retrieval time, and SHA-256, plus baseline provenance for Apple overrides.

Original source bytes, image formats, and dimensions are preserved. No cropping, resizing, retouching, recoloring, conversion, or generated imagery is applied. Identical content is deduplicated by SHA-256. These are third-party photographs; copyright and other rights remain with their respective owners.

Run `python3 Resources/update-device-photos.py` to refresh the IPSW.me baseline and apply Apple overrides. Use `--apple-only` to reuse the current baseline and unchanged bundled photos while applying the reviewed Apple overrides, without re-fetching every IPSW.me image. Removed overrides revert to their recorded fallback photo. Cache keys hash the full source URL.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--html-dir", type=Path, help="Reuse iphone.html and ipad.html baseline listings")
    parser.add_argument("--cache-dir", type=Path, help="Keep original image bytes, keyed by full URL")
    parser.add_argument("--output", type=Path, default=ROOT / "Sources/RestoreDock/Resources/DevicePhotos")
    parser.add_argument("--apple-overrides", type=Path, default=ROOT / "Resources/apple-iphone-photos.json")
    parser.add_argument("--apple-only", action="store_true", help="Reuse the bundled baseline and unchanged photos")
    args = parser.parse_args()
    overrides = json.loads(args.apple_overrides.read_text())
    old_manifest, old_models, photos = existing_assets(args.output, args.apple_only)
    devices = baseline(args, old_models)
    apply_overrides(devices, overrides)
    now = datetime.now(timezone.utc).isoformat()
    with tempfile.TemporaryDirectory(prefix="restoredock-photos-") as scratch:
        cache = args.cache_dir or Path(scratch)
        cache.mkdir(parents=True, exist_ok=True)

        def download(url):
            hosts = {"ipsw.me"} if urlparse(url).hostname == "ipsw.me" else APPLE_HOSTS
            checked_url(url, hosts)
            original = cache / (hashlib.sha256(url.encode()).hexdigest() + ".image")
            data = original.read_bytes() if original.exists() else fetch(url, hosts)
            record = image_record(data, url)
            if not original.exists():
                atomic_write(original, data)
            return url, record

        needed = sorted({item["url"] for item in devices.values()} - photos.keys())
        with ThreadPoolExecutor(max_workers=4) as pool:
            photos.update(dict(pool.map(download, needed)))
    # All overrides and downloads are valid before changing bundled assets or metadata.
    args.output.mkdir(parents=True, exist_ok=True)
    manifest, models = {}, {}
    for identifier, details in sorted(devices.items()):
        filename, digest, data = photos[details["url"]]
        manifest[identifier] = filename
        previous = old_models.get(identifier, {})
        retrieved = previous.get("retrieved_at") if previous.get("url") == details["url"] else now
        models[identifier] = dict(details, filename=filename, sha256=digest, retrieved_at=retrieved or now)
        atomic_write(args.output / filename, data)
    metadata = dict(updated_at=now, listings=list(PAGES.values()),
                    transformation="None. Original source bytes, original format, original dimensions.", models=models)
    atomic_write(args.output / "provenance.json", (json.dumps(metadata, indent=2) + "\n").encode())
    atomic_write(args.output / "SOURCES.md", source_notes(metadata, manifest).encode())
    atomic_write(args.output / "manifest.json", (json.dumps(manifest, indent=2) + "\n").encode())
    for filename in set(old_manifest.values()) - set(manifest.values()):
        if ASSET_NAME.fullmatch(filename) and not (args.output / filename).is_symlink():
            (args.output / filename).unlink(missing_ok=True)
    print(f"Saved {len(manifest)} models, {sum(m['provider'] == 'Apple' for m in models.values())} Apple overrides, {len(set(manifest.values()))} unique images.")


if __name__ == "__main__":
    main()
