#!/usr/bin/env python3
"""Write SideStore / AltStore sources for Ledger X from the GitHub releases.

release.json  the published versions (v*), newest first
dev.json      the latest dev build first, then the published versions

Usage: sidestore_source.py <owner/repo> <out dir>   (needs `gh` with a token)

With SIDESTORE_MIRROR set (the Cloudflare Worker in tools/cloudflare, e.g. https://ledger.example.com), the
sources name the mirror as their address and every download goes through it, so a source added from GitHub
moves to the mirror on its next refresh.
"""
import json, os, re, subprocess, sys

repo, out = sys.argv[1], sys.argv[2]
raw = f"https://raw.githubusercontent.com/{repo}"
ICON = "Ledger/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
# SideStore keeps images by address: the icon's contents in the address make a new icon a new address
icon_id = subprocess.check_output(["git", "hash-object", ICON], text=True).strip()[:10]
icon = f"{raw}/main/{ICON}?v={icon_id}"
tint = "2B806A"
mirror = os.environ.get("SIDESTORE_MIRROR", "").strip().rstrip("/")
DL = f"https://github.com/{repo}/releases/download/"


def link(url, version):
    """the IPA's address: through the mirror when there is one (the version keeps the dev build's cache fresh)"""
    if mirror and url.startswith(DL):
        return f"{mirror}/dl/{url[len(DL):]}?v={version}"
    return url

releases = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/releases?per_page=50"]))


def entry(r, version, desc):
    ipa = next((a for a in r.get("assets", []) if a["name"] == "Ledger.ipa"), None)
    if not ipa:
        return None
    m = re.search(r"构建 (\d+)", r.get("body") or "")
    return {
        "version": version,
        "buildVersion": m.group(1) if m else "",
        "date": r.get("published_at") or r["created_at"],
        "localizedDescription": desc,
        "downloadURL": link(ipa["browser_download_url"], version),
        "size": ipa["size"],
        "minOSVersion": "17.0",
    }


def notes(body):
    # the CHANGELOG part, without the install note under "---"
    return (body or "").split("\n---\n")[0].strip() or "Ledger X"


published = []
for r in releases:
    if re.match(r"^v\d+(\.\d+)*$", r["tag_name"]):
        e = entry(r, r["tag_name"][1:], notes(r.get("body")))
        if e:
            published.append(e)

dev = []
for r in releases:
    if r["tag_name"] == "dev":
        m = re.search(r"版本 (\S+?)[ ·]", r.get("body") or "")
        if m:
            e = entry(r, m.group(1), "开发版：" + (r.get("body") or "").split("。")[0])
            if e:
                dev.append(e)

about = ("原生 SwiftUI 的 Beancount 记账 / 查账 App。账本放在你自己的 Git 仓库或文件夹里，"
         "手机上记账、对账、看报表、跑 BQL 查询。")


def source(kind, name, versions):
    app = {
        "name": "Ledger X",
        "bundleIdentifier": "com.iskerwin.ledger",
        "developerName": "iskerwin",
        "subtitle": "Beancount 记账",
        "localizedDescription": about,
        "iconURL": icon,
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
        "name": name,
        "identifier": f"com.iskerwin.ledger.{kind}",
        "sourceURL": f"{mirror}/{kind}.json" if mirror else f"{raw}/sidestore/{kind}.json",
        "subtitle": "Beancount 记账",
        "description": about,
        "iconURL": icon,
        "website": f"https://github.com/{repo}",
        "tintColor": tint,
        "apps": [app],
        "news": [],
    }


os.makedirs(out, exist_ok=True)
for kind, name, versions in [("release", "Ledger X", published), ("dev", "Ledger X 开发版", dev + published)]:
    with open(os.path.join(out, kind + ".json"), "w", encoding="utf-8") as f:
        json.dump(source(kind, name, versions), f, ensure_ascii=False, indent=2)
    print(kind, [v["version"] for v in versions])
