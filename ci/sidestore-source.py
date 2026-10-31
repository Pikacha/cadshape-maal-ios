#!/usr/bin/env python3
"""Writes the SideStore/AltStore source (sidestore.json) for CadSHAPE Mål.

Everything is read from the built app, so the source always matches the IPA:
version, build number, bundle ID, minimum iOS, the privacy texts and the entitlements.
SideStore refuses an app whose permissions differ from the source, so nothing is typed by hand.

  python3 ci/sidestore-source.py <CadshapeMaal.app> <CadshapeMaal.ipa> <out.json>
"""
import datetime
import json
import os
import plistlib
import subprocess
import sys

REPO = "https://github.com/Pikacha/cadshape-maal-ios"
RAW = "https://raw.githubusercontent.com/Pikacha/cadshape-maal-ios/source"

app, ipa, out = sys.argv[1:4]
with open(os.path.join(app, "Info.plist"), "rb") as f:
    info = plistlib.load(f)

entitlements = []
try:
    der = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", app],
        capture_output=True, check=True,
    ).stdout
    if der.strip():
        ignore = {"application-identifier", "com.apple.developer.team-identifier"}
        entitlements = sorted(k for k in plistlib.loads(der) if k not in ignore)
except (subprocess.CalledProcessError, plistlib.InvalidFileException, FileNotFoundError):
    pass

privacy = {k: v for k, v in sorted(info.items()) if k.endswith("UsageDescription")}

source = {
    "name": "CadSHAPE",
    "subtitle": "Appene til CadSHAPE",
    "description": "Oppdateringer av CadSHAPE Mål rett fra GitHub-bygget.",
    "iconURL": f"{RAW}/icon.png",
    "website": "https://kloki.no/cadshape",
    "tintColor": "#ff7a1a",
    "apps": [
        {
            "name": info.get("CFBundleDisplayName", "CadSHAPE Mål"),
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "Pikacha",
            "subtitle": "Mål, skann og se delene dine i AR",
            "localizedDescription": (
                "Mål hull og rom med LiDAR, 3D-skann ting, se delene dine i AR og følg "
                "printen fra telefonen. Kobles til CadSHAPE på PC-en eller på kloki.no/cadshape."
            ),
            "iconURL": f"{RAW}/icon.png",
            "tintColor": "#ff7a1a",
            "category": "utilities",
            "versions": [
                {
                    "version": info["CFBundleShortVersionString"],
                    "buildVersion": str(info["CFBundleVersion"]),
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "localizedDescription": f"Bygd fra {os.environ.get('GITHUB_SHA', '?')[:7]}.",
                    "downloadURL": f"{REPO}/releases/download/latest/CadshapeMaal.ipa",
                    "size": os.path.getsize(ipa),
                    "minOSVersion": info.get("MinimumOSVersion", "17.0"),
                }
            ],
            "appPermissions": {"entitlements": entitlements, "privacy": privacy},
        }
    ],
    "news": [],
}

with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(json.dumps(source["apps"][0]["versions"][0], indent=2))
print("entitlements:", entitlements, "privacy:", list(privacy))
