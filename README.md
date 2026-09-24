# playwright-chromium-win-arm64

Build **open-source Chromium** for **Windows ARM64**, then pack it into the Playwright 1.62 layout so Nexora / MiWork can ship `playwright-chromium` for `windows/aarch64`.

中文说明见下方；English summary first.

## English (short)

| Pin | Value |
|-----|--------|
| Playwright Python | **1.62.0** (do not bump) |
| Chromium revision | **1234** |
| Chrome / CFT tag | **151.0.7922.34** |
| Nexora package | `playwright-chromium-windows-aarch64-1.62.1234+cn.1` |
| Layout | `chromium-1234/chrome-win64/chrome.exe` |
| PE Machine | **AA64** (ARM64) |

Official CFT / Playwright **win-arm64** zips are **404**. This repo compiles Chromium on GitHub-hosted **Windows ARM** runners (same approach as [AtlasGraph](https://github.com/xjfyt/AtlasGraph) — see [`.github/workflows/release.yml`](https://github.com/xjfyt/AtlasGraph/blob/master/.github/workflows/release.yml): `runs-on: windows-11-arm`).

**Default build label here:** `windows-11-vs2026-arm` (VS 2026 + MSVC ARM64, better for Chromium). Workflow input can switch to `windows-11-arm` to match AtlasGraph exactly. **Do not** use self-hosted unless you choose to; **do not** redistribute Google Chrome / Edge.

## CI pipeline (multi-stage)

Hosted Actions jobs hard-cap at **6 hours** (`timeout-minutes` above 360 does not help). Full Chromium src does **not** fit in Actions cache/artifacts (~10GB).

1. **probe** — HEAD-check official win-arm64 zips  
2. **sync** — `gclient` sync + warm `depot_tools` / gclient object cache (Actions cache; save may fail if >~10GB)  
3. **build** — restore cache, sync again (faster on hit), compile `chrome`, pack, Release  

Also: when `DELETE_GIT_AFTER_SYNC=1`, skip `git gc --aggressive` and delete `.git` immediately (aggressive gc burned ~4h with no compile on run 35622650851).

Hosted ARM images have **tight disk** (~14 GB free is common). Scripts use aggressive reclaim (`symbol_level=0`, no pdb, optional delete `.git` after sync). If the job fails on disk, keep the label and inspect logs — do not silently change runners.

**No binary ships in git.** Trigger **Build Windows ARM64 Chromium** after push.

---

## 目的

为 Playwright Python **1.62.0** 补齐 **windows/aarch64**：

- CFT / Playwright CDN **没有** win-arm64 公开包（404）
- Playwright 1.62 **没有** `win-arm64` 路径，只认 `chrome-win64/chrome.exe`
- 在 GitHub 托管 **Windows ARM** runner 上编译开源 Chromium 再打包
- **禁止**打包 Program Files 里的 Chrome / Edge

## 版本钉（请勿改）

| 项 | 值 |
|----|----|
| Playwright Python | `1.62.0` |
| Chromium revision | `1234` |
| Chrome tag | `151.0.7922.34` |
| 包名 | `playwright-chromium-windows-aarch64-1.62.1234+cn.1` |
| 布局 | `chromium-1234/chrome-win64/chrome.exe` |
| PE | `AA64` |

## Runner 标签（参考 AtlasGraph）

[AtlasGraph `release.yml`](https://github.com/xjfyt/AtlasGraph/blob/master/.github/workflows/release.yml) 注释写明：GitHub Actions **原生支持** Windows ARM，矩阵使用：

```yaml
runs-on: windows-11-arm
```

本仓构建 job：

```yaml
runs-on: windows-11-vs2026-arm   # 默认；workflow_dispatch 可选 windows-11-arm
```

| Label | 说明 |
|-------|------|
| `windows-11-vs2026-arm` | 默认。Windows 11 ARM64 + Visual Studio 2026（含 MSVC ARM64） |
| `windows-11-arm` | 与 AtlasGraph 完全一致的托管标签 |

两者同属 GitHub **hosted** Windows ARM，不是 self-hosted。

## 磁盘与激进节省

Chromium 通常需要 **≥100 GB** 空闲；托管 ARM 镜像往往远小于此。脚本默认（CI）：

- `DEPOT_TOOLS_WIN_TOOLCHAIN=0`
- `is_official_build=true` / `symbol_level=0` / `blink_symbol_level=0`（避免 pdb）
- sync 后可选删除 `src\.git`（`DELETE_GIT_AFTER_SYNC`）
- **不要**删除 `third_party\rust-toolchain\lib\rustlib\src`（Rust host compiler-builtins 需要 `build.rs`）；**不要**删除 `third_party\llvm-build\Release+Asserts\lib`（Rust host 需要 `clang_rt.builtins-x86_64.lib`）
- 编完清理 `out\Default\obj` / `gen` / `*.pdb`
- 打包只保留运行时文件到 `chromium-1234/chrome-win64/`

若仍因磁盘失败：保留 workflow 与日志，向维护者报告，**不要**悄悄改成别的 runner。

## 探测上游

`probe`（`ubuntu-latest`）与每周 `probe-upstream` 会对三个公开 URL 做 HEAD；若出现 **200** 会 notice / 开 issue，应优先用官方包。

## Release 产物

Tag：`v1.62.1234-cn.1`  

- `playwright-chromium-windows-aarch64-1.62.1234+cn.1.7z`（或 zip）
- 同名 `.json`（sha256、`exe_rel_path` 等）

## 仓库内容

| 路径 | 作用 |
|------|------|
| [docs/BUILD.md](docs/BUILD.md) | 手工编译步骤 |
| [scripts/build-chromium-win-arm64.ps1](scripts/build-chromium-win-arm64.ps1) | §2–§4 自动化 + 磁盘回收 |
| [scripts/pack-playwright-layout.mjs](scripts/pack-playwright-layout.mjs) | Playwright 布局 + sha256 |
| [.github/workflows/build-win-arm64.yml](.github/workflows/build-win-arm64.yml) | `workflow_dispatch` → probe + build + Release |
| [.github/workflows/probe-upstream.yml](.github/workflows/probe-upstream.yml) | 每周探测 |

## 许可证

- 脚本 / workflow：**BSD-3-Clause**（[LICENSE](LICENSE)）
- 二进制：Chromium 开源许可；**不是** Chrome / Edge

## 下一步

1. 确认 Actions 已启用  
2. Actions → **Build Windows ARM64 Chromium** → Run workflow（默认 `windows-11-vs2026-arm`）  
3. 等待（可能数小时；也可能因磁盘失败——保留日志）  
4. 从 Release `v1.62.1234-cn.1` 取 `.7z`/`.zip` + `.json` 上传 Nexora  

当前仓库 **尚未** 包含 Chromium 二进制（预期如此）。
