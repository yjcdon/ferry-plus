# Ferry Plus

**A simple native macOS client for Baidu Netdisk and Quark Drive.**

Browse cloud files, upload and download, and manage both drives in one Mac app. Built with Swift and SwiftUI, based on [Ferry](https://github.com/yiquncode/BaiduPCS-Swift).

[Download](https://github.com/yjcdon/ferry-plus/releases/latest) · [简体中文](README.md) · [Changelog](CHANGELOG.md)

Requires **macOS 14+ and Apple Silicon (M-series Macs)**. Open source under Apache 2.0. The current app interface is in Chinese.

## Features

- **Two drives, one app:** sign in to Baidu and Quark, switch drives, browse folders, search the current directory, and sort files.
- **Uploads and downloads:** upload files or folders with drag and drop; download cloud files and shared links while preserving folder structure.
- **File management:** create folders from the empty-area context menu and name them inline; rename items inline and move selected files or folders to the cloud recycle bin.
- **Transfer queue:** pause, resume, retry failures, and filter by drive, direction, or status.
- **Content checks:** verify transfer content in the background; store credentials in the local macOS Keychain.

Choose files or folders to start uploading immediately, or drop them into the current directory or a target folder. Same-name files keep both copies by default. Track progress in the transfer queue.

## Install

### Homebrew

```sh
brew tap yjcdon/ferry-plus https://github.com/yjcdon/ferry-plus
brew install --cask yjcdon/ferry-plus/ferry-plus
```

To update:

```sh
brew update
brew upgrade --cask yjcdon/ferry-plus/ferry-plus
```

If Homebrew asks you to trust the source, run `brew trust --cask yjcdon/ferry-plus/ferry-plus` and install again.

### Download the app

Get the arm64 ZIP from [Releases](https://github.com/yjcdon/ferry-plus/releases/latest), unzip it, and move **Ferry Plus.app** to Applications. A SHA-256 checksum is provided with each release.

The app is currently not notarized by Apple. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**.

## Quick start

1. Open the account menu and sign in through the provider’s official login page.
2. Select a drive in the sidebar. Drop local files to upload, or select cloud files and click Download.
3. Open Transfers to track progress. Use “查看全部” to show tasks from both drives.

Use the link button in the toolbar to add a shared link.

## FAQ

**What determines download speed?** Your network, the provider’s service, and your account permissions. Connection settings adjust concurrency; membership benefits are provided by the cloud service.

**Which Macs are supported?** Apple Silicon Macs running macOS 14 or later.

**Where are credentials stored?** In the local macOS Keychain. The app connects directly to the cloud providers. Release packages contain the application and resources; account and task data stay on each user’s Mac.

**How does this relate to Ferry?** Ferry Plus extends Ferry with Quark Drive, uploads to both providers, and integrated file management. The two apps can coexist with separate accounts and settings.

## Development

[Build from source (Chinese)](docs/build.md) · [Design documents (Chinese)](docs/README.md) · [Verification status (Chinese)](docs/v4.1/test-execution.md)

Report bugs and suggestions in [Issues](https://github.com/yjcdon/ferry-plus/issues), including the app version, macOS version, and reproduction steps. Redact account details and private file information.

## Credits and license

Based on [Ferry / BaiduPCS-Swift](https://github.com/yiquncode/BaiduPCS-Swift). Baidu API usage also draws on [BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go).

[Apache License 2.0](LICENSE)
