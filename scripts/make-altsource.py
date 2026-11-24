#!/usr/bin/env python3
"""Generates an AltStore / SideStore compatible source (apps.json) from the
repository's GitHub releases. Every release tagged vX.Y.Z that carries an
.ipa asset becomes one version entry (newest first)."""
import argparse
import json
import os
import plistlib
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "io.github.westernpluto.shiro"


def gh(url: str):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    info = plistlib.loads((ROOT / "Shiro" / "Info.plist").read_bytes())
    ents = plistlib.loads((ROOT / "Shiro" / "Shiro.entitlements").read_bytes())
    privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}

    releases = []
    page = 1
    while True:
        batch = gh(f"https://api.github.com/repos/{args.repo}/releases?per_page=100&page={page}")
        if not batch:
            break
        releases += batch
        page += 1

    versions = []
    for rel in releases:
        tag = rel.get("tag_name", "")
        if rel.get("draft") or not tag.startswith("v"):
            continue
        ipa = next((a for a in rel.get("assets", []) if a["name"].endswith(".ipa")), None)
        if not ipa:
            continue
        version = tag[1:]
        notes = (rel.get("body") or "").split("**Install:**")[0].strip()
        versions.append({
            "version": version,
            "buildVersion": version.split(".")[-1],
            "date": rel.get("published_at") or rel.get("created_at"),
            "localizedDescription": notes[:4000] or f"Shiro {version}",
            "downloadURL": ipa["browser_download_url"],
            "size": ipa["size"],
            "minOSVersion": "17.0",
        })

    def key(v):
        return [int(p) if p.isdigit() else 0 for p in v["version"].split(".")]

    versions.sort(key=key, reverse=True)
    base = f"https://github.com/{args.repo}"
    icon = f"{base}/releases/download/altsource/icon.png"

    source = {
        "name": "Shiro",
        "identifier": BUNDLE_ID + ".source",
        "subtitle": "PlayStation Remote Play, built for iPhone Duo",
        "description": "Official build feed for Shiro — a PS4 / PS5 / PS5 Pro Remote Play client.",
        "iconURL": icon,
        "website": base,
        "tintColor": "#3D7BFF",
        "featuredApps": [BUNDLE_ID],
        "apps": [{
            "name": "Shiro",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "westernpluto",
            "subtitle": "PS4 / PS5 / PS5 Pro Remote Play",
            "localizedDescription": (
                "Stream your PlayStation 4, PlayStation 5 and PS5 Pro to your iPhone — at home or over the internet.\n\n"
                "• Designed for iPhone Duo: adapts to the outer and inner displays and every fold pose\n"
                "• HDR (HEVC Main10 / PQ) up to 1080p60 at up to 50 Mbps\n"
                "• Low-latency hardware decode with tight audio/video sync\n"
                "• Remote Play over the internet via PSN (no port forwarding)\n"
                "• Automatic (PIN-less) console registration via PSN\n"
                "• Multiple controllers (DualSense, DualShock 4, Xbox, MFi) with merge / hand-off couch co-op modes\n"
                "• DualSense adaptive triggers, rumble, light bar, touchpad and motion\n"
                "• External display output (USB-C / AirPlay) with the phone as a companion touchpad\n"
                "• Microphone support"
            ),
            "iconURL": icon,
            "tintColor": "#3D7BFF",
            "category": "games",
            "versions": versions,
            "appPermissions": {
                "entitlements": sorted(k for k in ents.keys()),
                "privacy": privacy,
            },
        }],
        "news": [],
    }
    Path(args.out).write_text(json.dumps(source, indent=2))
    print(f"Wrote {args.out} with {len(versions)} version(s)")


if __name__ == "__main__":
    main()
