#!/usr/bin/env python3
"""Write the Ledger X IPA sources (for SideStore, AltStore, Zeus and similar) from the GitHub releases.

Published on the `ipa` branch, in two variants with the same file names:

  dev.json, release.json                 every address points directly at GitHub
  mirror/dev.json, mirror/release.json   every address (source, icon, IPA) goes through gh-proxy.com

release.json lists the published versions (v*), newest first; dev.json the latest dev build
first, then the published versions.

Usage: ipa_source.py <owner/repo> <out dir>   (needs `gh` with a token)
"""
import json, os, re, subprocess, sys

repo, out = sys.argv[1], sys.argv[2]
raw = f"https://raw.githubusercontent.com/{repo}"
ICON = "Ledger/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
# SideStore keeps images by address: the icon's contents in the address make a new icon a new address
icon_id = subprocess.check_output(["git", "hash-object", ICON], text=True).strip()[:10]
icon = f"{raw}/main/{ICON}?v={icon_id}"
tint = "2B806A"
BRANCH = "ipa"
MIRROR = "https://gh-proxy.com/"


def via_mirror(url):
    return MIRROR + url


def source_url(kind, mirrored):
    path = f"{raw}/{BRANCH}/{'mirror/' if mirrored else ''}{kind}.json"
    return via_mirror(path) if mirrored else path

pages = json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"]))
releases = [r for page in pages for r in page]


def entry(r, version, desc):
    ipa = next((a for a in r.get("assets", []) if a["name"] == "Ledger.ipa"), None)
    if not ipa:
        return None
    m = re.search(r"构建 (\d+(?:\.\d+)*)", r.get("body") or "")
    return {
        "version": version,
        "buildVersion": m.group(1) if m else "",
        "date": r.get("published_at") or r["created_at"],
        "localizedDescription": desc,
        "downloadURL": ipa["browser_download_url"],
        "size": ipa["size"],
        "minOSVersion": "17.0",
    }


def notes(body):
    # the CHANGELOG part, without the install note under "---"
    return (body or "").split("\n---\n")[0].strip() or "Ledger X"


published = []
for r in releases:
    if not r.get("draft") and not r.get("prerelease") and re.fullmatch(r"v\d+\.\d+\.\d+", r["tag_name"]):
        e = entry(r, r["tag_name"][1:], notes(r.get("body")))
        if e:
            published.append(e)

published.sort(key=lambda v: tuple(map(int, v["version"].split("."))), reverse=True)

dev = []
for r in releases:
    if r["tag_name"] == "dev" and not r.get("draft"):
        m = re.search(r"版本 (\S+?)[ ·]", r.get("body") or "")
        if m:
            e = entry(r, m.group(1), notes(r.get("body")))
            if e:
                dev.append(e)

about = ("原生 SwiftUI 的 Beancount 记账 / 查账 App。账本放在你自己的 Git 仓库或文件夹里，"
         "手机上记账、对账、看报表、跑 BQL 查询。")


def mirrored_versions(versions):
    # The dev IPA keeps one address across builds; the query makes each build a new address for the proxy cache.
    return [dict(v, downloadURL=via_mirror(f"{v['downloadURL']}?v={v['version']}-{v['buildVersion']}")) for v in versions]


def source(kind, name, versions, mirrored):
    versions = mirrored_versions(versions) if mirrored else versions
    app = {
        "name": "Ledger X",
        "bundleIdentifier": "com.iskerwin.ledger",
        "developerName": "iskerwin",
        "subtitle": "Beancount 记账",
        "localizedDescription": about,
        "iconURL": via_mirror(icon) if mirrored else icon,
        "tintColor": tint,
        "category": "utilities",
        "versions": versions,
        "appPermissions": {
            "entitlements": [],
            "privacy": {
                "NSCameraUsageDescription": "拍摄票据作为交易附件",
                "NSFaceIDUsageDescription": "使用面容 ID 解锁账本",
                "NSPhotoLibraryUsageDescription": "选择票据照片作为交易附件",
            },
        },
    }
    if versions:
        # older SideStore / AltStore read the top-level fields
        v = versions[0]
        app.update({"version": v["version"], "versionDate": v["date"], "versionDescription": v["localizedDescription"],
                    "downloadURL": v["downloadURL"], "size": v["size"]})
    return {
        "name": f"{name}（镜像）" if mirrored else name,
        "identifier": f"com.{repo.replace('/', '.')}.{kind}" + (".mirror" if mirrored else ""),
        "sourceURL": source_url(kind, mirrored),
        "subtitle": "Beancount 记账",
        "description": about,
        "iconURL": via_mirror(icon) if mirrored else icon,
        "website": f"https://github.com/{repo}",
        "tintColor": tint,
        "apps": [app],
        "news": [],
    }


for mirrored in (False, True):
    folder = os.path.join(out, "mirror") if mirrored else out
    os.makedirs(folder, exist_ok=True)
    for kind, name, versions in [("release", "Ledger X", published), ("dev", "Ledger X 开发版", dev + published)]:
        with open(os.path.join(folder, kind + ".json"), "w", encoding="utf-8") as f:
            json.dump(source(kind, name, versions, mirrored), f, ensure_ascii=False, indent=2)
        print(("mirror/" if mirrored else "") + kind, [v["version"] for v in versions])
