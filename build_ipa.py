#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
熬夜看短剧 — 一键云端打包 IPA
================================
本机是 Windows 编不了 iOS，本脚本走项目自带的 GitHub Actions（macos-latest）
在云端编译，然后把 IPA 自动下载回本地。

用法：
    python 一键打包IPA.py <你的GitHub_PAT>

PAT 权限（fine-grained token）：
    - Contents: read and write
    - Actions: read and write
    - Metadata: read
  （classic token 勾 repo 即可）

脚本会全自动完成：
    1. 用 token 反查你的用户名
    2. 创建/复用公开仓库 chengguo
    3. 推送本目录修复后的源码（含新增 Keychain.swift）
    4. 等待 Build Unsigned IPA 工作流跑完（约 5~10 分钟）
    5. 下载 artifact，解压出 ChengGuo-unsigned.ipa 到本目录

只需一个 PAT，其余不用管。
"""
import os
import sys
import json
import time
import zipfile
import io
import subprocess
import urllib.request
import urllib.error

API = "https://api.github.com"
REPO_NAME = "chengguo"
WORKFLOW = "build-ipa.yml"
HERE = os.path.dirname(os.path.abspath(__file__))


def get_token():
    if len(sys.argv) > 1:
        return sys.argv[1].strip()
    return os.environ.get("GH_TOKEN", "").strip()


TOKEN = get_token()
if not TOKEN:
    print("用法: python 一键打包IPA.py <你的GitHub_PAT>")
    print("或先设置环境变量 GH_TOKEN 再直接运行。")
    sys.exit(1)

HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "chengguo-ipa-builder",
}


def api(method, path, data=None, raw=False):
    url = API + path
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            content = resp.read()
            return content if raw else (json.loads(content.decode("utf-8")) if content else None)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "ignore")[:300]
        raise RuntimeError(f"API 失败 {method} {path} -> HTTP {e.code}: {detail}")


def run(cmd, check=True):
    print(f"  $ {' '.join(cmd[:3])}{' ...' if len(cmd) > 3 else ''}")
    r = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"命令失败: {cmd}\n{r.stdout}\n{r.stderr}")
    return r


def main():
    print("[1/5] 反查 GitHub 用户...")
    user = api("GET", "/user")
    owner = user["login"]
    print(f"  账号: {owner}")

    print("[2/5] 创建/复用仓库...")
    path = f"/repos/{owner}/{REPO_NAME}"
    try:
        api("GET", path)
        print(f"  复用已有仓库 {owner}/{REPO_NAME}")
    except RuntimeError:
        api("POST", "/user/repos", {
            "name": REPO_NAME,
            "private": False,
            "description": "熬夜看短剧 iOS 源码（15 bug 修复版）",
            "auto_init": False,
        })
        print(f"  已创建仓库 {owner}/{REPO_NAME}")

    print("[3/5] 推送修复后的源码...")
    run(["git", "remote", "remove", "origin"], check=False)
    auth_url = f"https://{TOKEN}@github.com/{owner}/{REPO_NAME}.git"
    run(["git", "remote", "add", "origin", auth_url])
    run(["git", "branch", "-M", "main"], check=False)
    run(["git", "add", "-A"])
    # 用本地身份提交（若脚本目录已有 commit 则跳过）
    r = run(["git", "diff", "--cached", "--quiet"], check=False)
    if r.returncode != 0:
        run(["git", "-c", "user.name=buddy", "-c", "user.email=buddy@local",
             "commit", "-m", "修复 15 个 bug 后的 iOS 源码"])
    run(["git", "push", "-f", "origin", "main"])
    print("  推送完成，Actions 已自动触发")

    print("[4/5] 等待云端编译（约 5~10 分钟）...")
    deadline = time.time() + 15 * 60
    run_id = None
    while time.time() < deadline:
        runs = api("GET", f"{path}/actions/runs?event=push&per_page=5")
        items = runs.get("workflow_runs", [])
        if items:
            latest = items[0]
            run_id = latest["id"]
            status = latest["status"]        # queued / in_progress / completed
            concl = latest.get("conclusion")  # success / failure / None
            if status == "completed":
                if concl != "success":
                    raise RuntimeError(f"云端编译失败: {concl}，去仓库 Actions 页看日志")
                print("  编译成功")
                break
            print(f"  状态: {status} ...")
        time.sleep(20)
    else:
        raise RuntimeError("等待超时，请去仓库 Actions 页确认")

    print("[5/5] 下载 IPA...")
    arts = api("GET", f"{path}/actions/runs/{run_id}/artifacts")
    artifacts = arts.get("artifacts", [])
    if not artifacts:
        raise RuntimeError("没找到 artifact，去 Actions 页确认")
    art = next((a for a in artifacts if "ipa" in a["name"].lower()), artifacts[0])
    print(f"  artifact: {art['name']}")
    zip_bytes = api("GET", f"/repos/{owner}/{REPO_NAME}/actions/artifacts/{art['id']}/zip", raw=True)
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        ipa_names = [n for n in zf.namelist() if n.lower().endswith(".ipa")]
        if not ipa_names:
            raise RuntimeError("artifact 里没有 .ipa 文件")
        for name in ipa_names:
            out = os.path.join(HERE, os.path.basename(name))
            with open(out, "wb") as f:
                f.write(zf.read(name))
            print(f"  已保存: {out}  ({len(zf.read(name))/1024/1024:.2f} MB)")

    print("\n完成！IPA 已下载到本目录，接下来用「全能签」自签后安装。")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"\n出错: {e}")
        sys.exit(1)
