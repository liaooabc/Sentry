#!/usr/bin/env python3
"""
生成 Resources/cask-map.json —— 那张「App 名 / bundle id → Homebrew Cask 名」的表。

为什么要有这张表：
  运行时只按需拉单个 cask 的 JSON（约 1KB），不下载 18MB 的完整索引。
  但要知道「Keka.app 对应 keka 这个 cask」，就得先有一张映射表，随 App 一起发布。

什么时候重新生成：
  - 想覆盖更多 App（社区新上架的 cask）时，每隔一两个月跑一次
  - 用法：python3 tools/make_cask_map.py

数据来源：https://formulae.brew.sh/api/cask.json（Homebrew 官方 API）

优先级（2026-11-20 加）：
  1) 现行 cask（没被 disabled / deprecated）
  2) 真带 .app 产物的（有些 cask 只是「顺带卸载某个 bundle id」，不该占坑）
  3) 正式版优先于 @beta/@alpha/@nightly 这类变体
  4) 剩下的按名字排，保证每次生成结果一致
  原因：Topaz 这类厂商会「换产品线」，老 cask 和新 cask 声明同一个 bundle id
  （com.topazlabs.TopazGigapixel），以前谁后写谁赢，结果把这台 1.5.x 的新版
  钉到了 8.4.4 的老 cask 上，永远显示「该更新到 8.4.4」。
  老 cask 仍保留给「装的确实是老版」的人：他们的 .app 文件名是
  「Topaz Gigapixel AI.app」，走名字匹配，不冲突。
"""
import json
import os
import re
import urllib.request

URL = "https://formulae.brew.sh/api/cask.json"
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "cask-map.json")

# 手工补的：pkg 安装（没有 .app 产物）或 .app 名字和 cask 里对不上的。
# 注意别在这里写「会换产品线」的 App（Topaz 就是）：那种交给下面两轮扫描按新旧自动取舍。
MANUAL = {
    "com.microsoft.Word": "microsoft-word",
    "com.microsoft.Excel": "microsoft-excel",
    "com.microsoft.Powerpoint": "microsoft-powerpoint",
    "com.microsoft.Outlook": "microsoft-outlook",
    "com.microsoft.onenote.mac": "microsoft-onenote",
    "com.canva.CanvaDesktop": "canva",
    # Topaz Video 装的是 pkg，cask 的 uninstall 段里只有包 id（com.topazlabs.VStudioPackage），
    # 对不上 App 自己的 bundle id，只能手工钉死。
    "com.topazlabs.Topaz-Video": "topaz-video",
    # Telegram 有两套：cask telegram 是原生版（ru.keepcoder.Telegram，13.x），
    # cask telegram-desktop 才是 Telegram Desktop（com.tdesktop.Telegram，7.x）。
    # 两者的 .app 都叫 Telegram.app，自动取舍时按 token 字母序把 Desktop 版
    # 钉到了原生版上，结果永远比不出东西。这里必须手工指定。
    "com.tdesktop.Telegram": "telegram-desktop",
}


def apps_of(cask):
    out = []
    for a in cask.get("artifacts", []):
        if isinstance(a, dict) and "app" in a:
            v = a["app"]
            for x in v if isinstance(v, list) else [v]:
                if isinstance(x, str):
                    out.append(x)
    return out


def bundles_of(cask):
    ids = set()
    for a in cask.get("artifacts", []):
        if isinstance(a, dict) and "uninstall" in a:
            for part in re.findall(r"[A-Za-z0-9][\w.-]*", json.dumps(a["uninstall"])):
                if part.count(".") >= 2 and not part.endswith((".app", ".pkg", ".dmg", ".plist")):
                    ids.add(part)
    return ids


def usable(cask):
    ver = (cask.get("version") or "").split(",")[0]
    return bool(ver) and ver != "latest" and ver[0].isdigit()


def main():
    print("▸ 下载 Homebrew Cask 索引（约 2MB 压缩传输）…")
    req = urllib.request.Request(URL, headers={"Accept-Encoding": "gzip",
                                              "User-Agent": "Sentry/1.x"})
    with urllib.request.urlopen(req, timeout=600) as r:
        raw = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            import gzip
            raw = gzip.decompress(raw)
    casks = json.loads(raw)
    print(f"  cask 总数 {len(casks)}")

    live = [c for c in casks if not (c.get("disabled") or c.get("deprecated"))]
    legacy = [c for c in casks if c.get("disabled") or c.get("deprecated")]
    print(f"  现行 {len(live)} / 已废弃 {len(legacy)}")

    def rank(c):
        """同一个 bundle id 被多个 cask 认领时的取舍顺序（越小越优先）。"""
        token = c["token"]
        return (
            1 if (c.get("disabled") or c.get("deprecated")) else 0,  # 现行优先
            0 if apps_of(c) else 1,                                   # 真装了 .app 的优先
            1 if "@" in token else 0,                                 # 正式版优先于 @beta 变体
            token,
        )

    def put(table, key, c):
        cur = table.get(key)
        if cur is None or rank(c) < rank(cur):
            table[key] = c

    app_casks, bundle_casks = {}, {}
    for c in casks:
        if not usable(c):
            continue
        for a in apps_of(c):
            put(app_casks, a.lower(), c)
        for b in bundles_of(c):
            put(bundle_casks, b, c)

    apps = {k: c["token"] for k, c in app_casks.items()}
    bundles = {k: c["token"] for k, c in bundle_casks.items()}
    bundles.update(MANUAL)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"apps": apps, "bundles": bundles}, f, ensure_ascii=False, separators=(",", ":"))
    print(f"▸ 写出 {os.path.normpath(OUT)}")
    print(f"  app 名 {len(apps)} 条 | bundle id {len(bundles)} 条 | {os.path.getsize(OUT)//1024} KB")


if __name__ == "__main__":
    main()
