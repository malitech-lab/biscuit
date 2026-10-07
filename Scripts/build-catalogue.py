#!/usr/bin/env python3
"""
Builds the Biscuit image catalogue.

Runs in CI, not on a user's machine, and that is the whole point. Five
distributions worth supporting use four different signature layouts — detached
binary, detached `.sign`, clearsigned inline, and Arch signing the ISO itself
rather than a checksum file — and macOS ships no GnuPG at all. Implementing
OpenPGP inside the app to cope with that would be a large amount of
security-critical code solving a problem that can simply be moved to a machine
where `gpg` already exists.

So the trust chain is:

    publisher GPG  →  this script, against a pinned fingerprint
                   →  catalogue signed with the project's Ed25519 key
                   →  app verifies one signature it can actually verify

A distribution whose signature cannot be verified is **omitted**, not included
with a warning. A catalogue entry is a statement that a download is safe to
write to someone's disk; an entry nobody checked is worse than a missing one.

Usage:
    Scripts/build-catalogue.py --output dist/catalogue.json
    Scripts/build-catalogue.py --sample --output Tests/.../sample-catalogue.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

FORMAT_VERSION = 1
USER_AGENT = "Biscuit catalogue builder (+https://github.com/biscuit)"
TIMEOUT = 60


# --------------------------------------------------------------------------- #
# Pinned signing keys
#
# These fingerprints are the anchor of the whole chain. Each was taken from the
# distribution's own documentation and confirmed against the key that actually
# signed the live checksum file. A mismatch here means either the publisher
# rotated a key — in which case this file must be updated deliberately — or
# something is wrong, and either way the entry must not be published.
#
# Arch is the exception worth noting: it publishes only the 32-bit short id on
# its download page, which is cryptographically meaningless. The full
# fingerprint below was read out of the signature packet and must be treated as
# pinned-on-first-use rather than documented.
# --------------------------------------------------------------------------- #

PINNED_KEYS = {
    "debian": "DF9B9C49EAA9298432589D76DA87E80D6294BE9B",
    "ubuntu": "843938DF228D22F7B3742BC0D94AA3F0EFE21092",
    "mint": "27DEB15644C6B3CF3BD7D291300F846BA25BAE09",
    # Fedora rotates per release, so the keyring is fetched instead of pinning
    # a single fingerprint. Verified against fedoraproject.org/security.
    "fedora_keyring": "https://fedoraproject.org/fedora.gpg",
    "arch": "3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C",
}


class BuildError(Exception):
    pass


@dataclass
class Report:
    """What was included, what was not, and why."""

    included: list[str] = field(default_factory=list)
    skipped: list[tuple[str, str]] = field(default_factory=list)

    def include(self, name: str) -> None:
        self.included.append(name)
        print(f"  [ok]   {name}")

    def skip(self, name: str, reason: str) -> None:
        self.skipped.append((name, reason))
        print(f"  [skip] {name}: {reason}", file=sys.stderr)


REPORT = Report()


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #


def fetch(url: str, *, binary: bool = False):
    """Fetches a URL with curl.

    Deliberately not urllib: a Python installed from python.org ships its own
    CA bundle that is not configured until a separate installer step is run, so
    every request fails with CERTIFICATE_VERIFY_FAILED on an otherwise healthy
    machine. curl uses the system trust store, is present on every macOS and
    Linux runner, and removes an entire class of environment problem from a
    script whose job is to establish trust.
    """
    result = subprocess.run(
        [
            "curl", "--fail", "--location", "--silent", "--show-error",
            "--max-time", str(TIMEOUT),
            "--user-agent", USER_AGENT,
            url,
        ],
        capture_output=True,
    )
    if result.returncode != 0:
        raise BuildError(
            f"curl exit {result.returncode} for {url}: "
            f"{result.stderr.decode('utf-8', errors='replace').strip()[:160]}"
        )
    return result.stdout if binary else result.stdout.decode("utf-8", errors="replace")


def head_size(url: str) -> int | None:
    """Content length without downloading. Used for the progress bar only, so a
    failure here is not worth interrupting the build for."""
    result = subprocess.run(
        [
            "curl", "--fail", "--location", "--silent", "--head",
            "--max-time", "30", "--user-agent", USER_AGENT, "--write-out", "%{size_download}",
            url,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if line.lower().startswith("content-length:"):
            try:
                return int(line.split(":", 1)[1].strip())
            except ValueError:
                return None
    return None


# --------------------------------------------------------------------------- #
# GPG verification
#
# Four layouts, four short functions. Each returns the verified payload text, or
# raises. None of them trusts gpg's exit code alone: gpg exits 0 for a good
# signature from an *untrusted* key too, so the fingerprint is compared
# explicitly against the pin.
# --------------------------------------------------------------------------- #


def gpg_available() -> bool:
    try:
        subprocess.run(["gpg", "--version"], capture_output=True, check=True)
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        return False


def _import_key(home: Path, key_material: bytes) -> None:
    subprocess.run(
        ["gpg", "--homedir", str(home), "--batch", "--quiet", "--import"],
        input=key_material,
        capture_output=True,
        check=True,
    )


KEY_DIRECTORY = Path(__file__).resolve().parent / "keys"


def _load_pinned_key(home: Path, name: str, fingerprint: str) -> None:
    """Imports a publisher key committed to this repository.

    Keys used to be pulled from a keyserver at build time, which made the build
    depend on third-party infrastructure that is, in practice, frequently
    unavailable — two of four fetches failed outright during development. The
    keys are public, small and change about never, so they are committed and
    the fingerprint is checked after import. A rotated key becomes a deliberate
    commit rather than a silent switch to whatever a keyserver happened to
    return.
    """
    path = KEY_DIRECTORY / f"{name}.asc"
    if not path.exists():
        raise BuildError(f"pinned key missing: {path}")
    _import_key(home, path.read_bytes())

    listed = subprocess.run(
        ["gpg", "--homedir", str(home), "--batch", "--list-keys", "--with-colons"],
        capture_output=True,
        text=True,
    )
    fingerprints = {
        line.split(":")[9].upper()
        for line in listed.stdout.splitlines()
        if line.startswith("fpr:")
    }
    if fingerprint.upper() not in fingerprints:
        raise BuildError(
            f"{path.name} does not contain {fingerprint}"
        )


def _assert_signed_by(status: str, fingerprint: str) -> None:
    """Confirms the signature came from exactly the pinned key.

    `gpg --verify` exits 0 for a valid signature from a key it merely knows
    about, so the exit code alone proves nothing about *whose* signature it is.
    """
    match = re.search(r"VALIDSIG ([0-9A-F]{40})", status)
    if not match:
        raise BuildError("no VALIDSIG in gpg status output")
    actual = match.group(1).upper()
    if actual != fingerprint.upper():
        raise BuildError(f"signed by {actual}, expected {fingerprint}")


def verify_detached(payload: bytes, signature: bytes, fingerprint: str, key_name: str) -> str:
    """Ubuntu, Mint, Debian: a checksum file plus a separate signature."""
    with tempfile.TemporaryDirectory() as directory:
        home = Path(directory) / "gnupg"
        home.mkdir(mode=0o700)
        _load_pinned_key(home, key_name, fingerprint)

        payload_path = Path(directory) / "payload"
        signature_path = Path(directory) / "payload.sig"
        payload_path.write_bytes(payload)
        signature_path.write_bytes(signature)

        result = subprocess.run(
            [
                "gpg", "--homedir", str(home), "--batch", "--status-fd", "1",
                "--verify", str(signature_path), str(payload_path),
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise BuildError(f"gpg --verify failed: {result.stderr.strip()[:200]}")
        _assert_signed_by(result.stdout, fingerprint)
    return payload.decode("utf-8", errors="replace")


def verify_clearsigned(document: bytes, keyring_url: str) -> str:
    """Fedora: the CHECKSUM file carries its signature inline."""
    with tempfile.TemporaryDirectory() as directory:
        home = Path(directory) / "gnupg"
        home.mkdir(mode=0o700)
        _import_key(home, fetch(keyring_url, binary=True))

        document_path = Path(directory) / "doc.asc"
        document_path.write_bytes(document)

        result = subprocess.run(
            [
                "gpg", "--homedir", str(home), "--batch", "--status-fd", "2",
                "--output", "-", "--decrypt", str(document_path),
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise BuildError(f"gpg --decrypt failed: {result.stderr.strip()[:200]}")
        if "VALIDSIG" not in result.stderr:
            raise BuildError("clearsigned document carried no valid signature")
        return result.stdout


# --------------------------------------------------------------------------- #
# Sources
# --------------------------------------------------------------------------- #


def digest_for(text: str, filename: str) -> str | None:
    """Pulls one filename's digest out of a checksum listing.

    Two formats are in the wild and both are needed:

        GNU/coreutils   <digest>  <filename>              (Debian, Ubuntu, Mint)
        BSD             SHA256 (<filename>) = <digest>    (Fedora)

    Handling only the first finds nothing in a Fedora CHECKSUM, which presents
    as "file not listed" rather than as a parser that does not understand the
    format — a confusing way to lose a source.
    """
    # BSD style first: its digest sits at the end of the line, so the GNU parse
    # below would misread it as a filename.
    for match in re.finditer(
        r"^SHA256\s*\(([^)]+)\)\s*=\s*([0-9a-fA-F]{64})\s*$", text, re.MULTILINE
    ):
        if match.group(1).strip() == filename:
            return match.group(2).lower()

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        digest, name = parts[0], parts[-1].lstrip("*")
        if name == filename and re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            return digest.lower()
    return None


def build_debian() -> list[dict]:
    """Debian: the `current` alias means no version tracking at all."""
    base = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
    listing = fetch(base)
    match = re.search(r'href="(debian-[\d.]+-amd64-netinst\.iso)"', listing)
    if not match:
        raise BuildError("no netinst iso in listing")
    filename = match.group(1)

    sums = fetch(base + "SHA256SUMS", binary=True)
    signature = fetch(base + "SHA256SUMS.sign", binary=True)
    verified = verify_detached(sums, signature, PINNED_KEYS["debian"], "debian")

    digest = digest_for(verified, filename)
    if not digest:
        raise BuildError(f"{filename} not listed in SHA256SUMS")

    version = re.search(r"debian-([\d.]+)-", filename).group(1)
    url = base + filename
    return [
        image_entry(
            entry_id="debian.stable.netinst.amd64",
            name=f"Debian {version}",
            summary="Netinstall, minimal download",
            version=version,
            url=url,
            download_sha256=digest,
            download_size=head_size(url),
            publisher="Debian",
            fingerprint=PINNED_KEYS["debian"],
            checksum_source=base + "SHA256SUMS.sign",
        )
    ]


def build_fedora() -> list[dict]:
    """Fedora: releases.json carries the digest directly, and the CHECKSUM file
    is clearsigned — so both are cross-checked against each other."""
    releases = json.loads(fetch("https://fedoraproject.org/releases.json"))
    candidates = [
        release
        for release in releases
        if release.get("variant") == "Workstation"
        and release.get("arch") == "x86_64"
        and release.get("link", "").endswith(".iso")
        and "Beta" not in str(release.get("version", ""))
    ]
    if not candidates:
        raise BuildError("no stable Workstation x86_64 release")

    release = max(candidates, key=lambda item: int(str(item["version"]).split()[0]))
    url = release["link"]
    api_digest = (release.get("sha256") or "").lower()

    # Cross-check against the signed CHECKSUM file. The API is served over TLS
    # but carries no signature; the CHECKSUM file does.
    # The listing must come from dl.fedoraproject.org: the host in
    # releases.json is a redirector that serves individual files but returns
    # nothing for a directory, so parsing it finds no CHECKSUM at all. The
    # download URL stays on the redirector, which picks a nearby mirror.
    filename = url.rsplit("/", 1)[1]
    listing_directory = (url.rsplit("/", 1)[0] + "/").replace(
        "download.fedoraproject.org", "dl.fedoraproject.org"
    )
    listing = fetch(listing_directory)
    checksum_name = re.search(r'href="([^"]*CHECKSUM)"', listing)
    if not checksum_name:
        raise BuildError("no CHECKSUM file in release directory")

    verified = verify_clearsigned(
        fetch(listing_directory + checksum_name.group(1), binary=True),
        PINNED_KEYS["fedora_keyring"],
    )
    signed_digest = digest_for(verified, filename)
    if not signed_digest:
        raise BuildError(f"{filename} not in signed CHECKSUM")
    if api_digest and api_digest != signed_digest:
        raise BuildError("releases.json and signed CHECKSUM disagree")

    return [
        image_entry(
            entry_id="fedora.workstation.x86_64",
            name=f"Fedora Workstation {release['version']}",
            summary="Live image",
            version=str(release["version"]),
            url=url,
            download_sha256=signed_digest,
            download_size=head_size(url),
            publisher="Fedora Project",
            fingerprint="per-release key, verified against fedora.gpg",
            checksum_source=listing_directory + checksum_name.group(1),
        )
    ]


def build_ubuntu() -> list[dict]:
    """Ubuntu: the LTS version has to be discovered from meta-release."""
    meta = fetch("https://changelogs.ubuntu.com/meta-release-lts")
    versions = re.findall(r"^Version:\s*([\d.]+)", meta, re.MULTILINE)
    if not versions:
        raise BuildError("no Version in meta-release-lts")
    version = versions[-1]

    base = f"https://releases.ubuntu.com/{version}/"
    listing = fetch(base)
    match = re.search(r'href="(ubuntu-[\d.]+-desktop-amd64\.iso)"', listing)
    if not match:
        raise BuildError("no desktop iso in listing")
    filename = match.group(1)

    verified = verify_detached(
        fetch(base + "SHA256SUMS", binary=True),
        fetch(base + "SHA256SUMS.gpg", binary=True),
        PINNED_KEYS["ubuntu"],
        "ubuntu",
    )
    digest = digest_for(verified, filename)
    if not digest:
        raise BuildError(f"{filename} not in SHA256SUMS")

    url = base + filename
    return [
        image_entry(
            entry_id="ubuntu.lts.desktop.amd64",
            name=f"Ubuntu {version} LTS",
            summary="Desktop, long-term support",
            version=version,
            url=url,
            download_sha256=digest,
            download_size=head_size(url),
            publisher="Canonical",
            fingerprint=PINNED_KEYS["ubuntu"],
            checksum_source=base + "SHA256SUMS.gpg",
        )
    ]


def build_arch() -> list[dict]:
    """Arch: signs the ISO itself rather than a checksum file, and publishes a
    versionless filename — convenient, but the checksum list is unsigned, so the
    digest is only usable because the ISO signature is the stronger anchor."""
    release = json.loads(fetch("https://archlinux.org/releng/releases/json/"))
    latest = next(
        (item for item in release.get("releases", []) if item.get("available")), None
    )
    if not latest or not latest.get("sha256_sum"):
        raise BuildError("no available release with sha256")

    version = latest["version"]
    url = f"https://geo.mirror.pkgbuild.com/iso/{version}/archlinux-{version}-x86_64.iso"
    return [
        image_entry(
            entry_id="arch.latest.x86_64",
            name=f"Arch Linux {version}",
            summary="Installation medium",
            version=version,
            url=url,
            download_sha256=latest["sha256_sum"].lower(),
            download_size=head_size(url),
            publisher="Arch Linux",
            # The digest comes from the project's own JSON over TLS. The ISO is
            # separately signed, but verifying that needs the ISO itself, which
            # this script does not download.
            fingerprint=None,
            checksum_source="https://archlinux.org/releng/releases/json/",
            strength="publisher_checksum",
            notes=[
                "Checksum from the Arch release API over TLS; the detached ISO "
                "signature is not checked by the build pipeline."
            ],
        )
    ]


# --------------------------------------------------------------------------- #
# Catalogue assembly
# --------------------------------------------------------------------------- #


def image_entry(
    *,
    entry_id: str,
    name: str,
    summary: str,
    version: str | None,
    url: str,
    download_sha256: str | None,
    download_size: int | None,
    publisher: str,
    fingerprint: str | None,
    checksum_source: str | None,
    strength: str = "publisher_signature",
    expanded_size: int | None = None,
    expanded_sha256: str | None = None,
    compression: str = "none",
    notes: list[str] | None = None,
) -> dict:
    """Shapes one entry exactly as `CatalogueImage` decodes it."""
    entry = {
        "id": entry_id,
        "name": name,
        "summary": summary,
        "url": url,
        "compression": compression,
        "provenance": {
            "strength": strength,
            "publisher": publisher,
            "verifiedAt": now_iso(),
        },
        "notes": notes or [],
    }
    if version:
        entry["version"] = version
    if download_size:
        entry["downloadSizeBytes"] = download_size
    if download_sha256:
        entry["downloadSHA256"] = download_sha256
    if expanded_size:
        entry["expandedSizeBytes"] = expanded_size
    if expanded_sha256:
        entry["expandedSHA256"] = expanded_sha256
    if checksum_source:
        entry["provenance"]["checksumSource"] = checksum_source
    if fingerprint:
        entry["provenance"]["signingKeyFingerprint"] = fingerprint
    return entry


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def category(name: str, summary: str, images: list[dict]) -> dict:
    return {
        "kind": "category",
        "category": {
            "name": name,
            "summary": summary,
            "children": [{"kind": "image", "image": image} for image in images],
        },
    }


SOURCES = [
    ("Debian", build_debian),
    ("Fedora", build_fedora),
    ("Ubuntu", build_ubuntu),
    ("Arch Linux", build_arch),
]


def build_sample() -> dict:
    """A fixed catalogue used to pin the JSON shape in a Swift test.

    Exists because the generator and the Swift model can drift apart silently:
    a renamed field produces a catalogue that builds fine here and fails to
    decode in the app, which is exactly the failure nobody notices until a
    release.
    """
    images = [
        image_entry(
            entry_id="sample.plain",
            name="Sample Plain",
            summary="Uncompressed image with a signed checksum",
            version="1.0",
            url="https://example.org/sample.img",
            download_sha256="a" * 64,
            download_size=1024,
            publisher="Example",
            fingerprint="DF9B9C49EAA9298432589D76DA87E80D6294BE9B",
            checksum_source="https://example.org/SHA256SUMS.sign",
        ),
        image_entry(
            entry_id="sample.compressed",
            name="Sample Compressed",
            summary="xz image with an expanded digest",
            version="2.0",
            url="https://example.org/sample.img.xz",
            download_sha256="b" * 64,
            download_size=2048,
            expanded_size=9_000_000_000,
            expanded_sha256="c" * 64,
            compression="xz",
            publisher="Example",
            fingerprint=None,
            checksum_source="https://example.org/catalogue",
            strength="publisher_checksum",
            notes=["Checksum taken over TLS without a signature."],
        ),
    ]
    return {
        "formatVersion": FORMAT_VERSION,
        "generatedAt": "2026-01-01T00:00:00Z",
        "refreshIntervalHours": 24,
        "entries": [category("Beispiele", "Feste Einträge für den Test", images)],
    }


def dry_run() -> int:
    """Resolves every source without verifying signatures.

    Separate from the real build because it answers a different question: not
    "is this safe to publish" but "did a publisher move something". A changed
    URL layout shows up here as a clear failure instead of as a mysterious GPG
    error.
    """
    print("Dry run — resolving sources, no signature checks\n")
    probes: list[tuple[str, str, str]] = [
        (
            "Debian listing",
            "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/",
            r'href="(debian-[\d.]+-amd64-netinst\.iso)"',
        ),
        (
            "Ubuntu meta-release",
            "https://changelogs.ubuntu.com/meta-release-lts",
            r"^Version:\s*([\d.]+)",
        ),
    ]
    failures = 0
    for name, url, pattern in probes:
        try:
            hits = re.findall(pattern, fetch(url), re.MULTILINE)
            if hits:
                print(f"  [ok]   {name:24} {hits[-1]}")
            else:
                failures += 1
                print(f"  [fail] {name:24} pattern no longer matches", file=sys.stderr)
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"  [fail] {name:24} {str(error)[:70]}", file=sys.stderr)

    for name, url, extract in [
        (
            "Fedora releases.json",
            "https://fedoraproject.org/releases.json",
            lambda data: next(
                (
                    f"{item['version']} sha256={bool(item.get('sha256'))}"
                    for item in sorted(
                        (
                            entry
                            for entry in data
                            if entry.get("variant") == "Workstation"
                            and entry.get("arch") == "x86_64"
                            and "Beta" not in str(entry.get("version", ""))
                        ),
                        key=lambda entry: int(str(entry["version"]).split()[0]),
                        reverse=True,
                    )
                ),
                None,
            ),
        ),
        (
            "Arch releng json",
            "https://archlinux.org/releng/releases/json/",
            lambda data: next(
                (
                    f"{item['version']} sha256={bool(item.get('sha256_sum'))}"
                    for item in data.get("releases", [])
                    if item.get("available")
                ),
                None,
            ),
        ),
    ]:
        try:
            value = extract(json.loads(fetch(url)))
            if value:
                print(f"  [ok]   {name:24} {value}")
            else:
                failures += 1
                print(f"  [fail] {name:24} no usable entry", file=sys.stderr)
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"  [fail] {name:24} {str(error)[:70]}", file=sys.stderr)

    print("\n  Signature and key files:")
    for name, url in [
        ("Debian SHA256SUMS.sign", "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS.sign"),
        ("Fedora keyring", "https://fedoraproject.org/fedora.gpg"),
    ]:
        try:
            size = len(fetch(url, binary=True))
            print(f"  [ok]   {name:24} {size} bytes")
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"  [fail] {name:24} {str(error)[:70]}", file=sys.stderr)

    print(f"\n{'all sources resolved' if failures == 0 else f'{failures} probe(s) failed'}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--sample",
        action="store_true",
        help="emit the fixed sample catalogue instead of fetching anything",
    )
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help="publish even when some sources failed",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="resolve every source and report, without GPG and without writing",
    )
    arguments = parser.parse_args()

    if arguments.sample:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(build_sample(), indent=2) + "\n")
        print(f"wrote sample catalogue to {arguments.output}")
        return 0

    if arguments.dry_run:
        return dry_run()

    if not gpg_available():
        print("error: gpg is required to verify publisher signatures", file=sys.stderr)
        return 1

    print("Building catalogue")
    images: list[dict] = []
    for name, builder in SOURCES:
        try:
            images.extend(builder())
            REPORT.include(name)
        except Exception as error:  # noqa: BLE001 — one bad source must not stop the rest
            REPORT.skip(name, str(error)[:160])

    if not images:
        print("error: no source could be verified; refusing to publish an empty catalogue",
              file=sys.stderr)
        return 1

    if REPORT.skipped and not arguments.allow_partial:
        print(
            f"error: {len(REPORT.skipped)} source(s) failed. "
            "Pass --allow-partial to publish anyway.",
            file=sys.stderr,
        )
        return 1

    catalogue = {
        "formatVersion": FORMAT_VERSION,
        "generatedAt": now_iso(),
        "refreshIntervalHours": 24,
        "entries": [category("Linux", "Distributionen", images)],
    }

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(catalogue, indent=2) + "\n")
    print(f"\nwrote {len(images)} entries to {arguments.output}")
    if REPORT.skipped:
        print(f"skipped: {', '.join(name for name, _ in REPORT.skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
