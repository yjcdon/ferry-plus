# Ferry Drive

Ferry Drive is an open-source desktop client for Baidu Netdisk and Quark Drive. Browse and manage files, transfer folders, and download shared links in one native app. Built with Go and MyGo, it runs on Apple Silicon Macs and Windows 10 or 11 x64. The app interface is in Chinese.

[Download 5.0.0](https://github.com/yjcdon/ferry-drive/releases/tag/v5.0.0) · [简体中文](README.md) · [Changelog](CHANGELOG.md)

## Features

- Sign in to both providers, switch between drives, and search, sort, or select multiple files.
- Upload files or folders with Finder drag and drop. Download cloud files and shared links while keeping their folder structure.
- Create folders, rename items, or move a selection to the cloud recycle bin.
- Pause, resume, retry, and filter tasks in the transfer queue.

## Install

| Platform | Download and install |
| --- | --- |
| macOS 14 or later, Apple Silicon | Extract `ferry-drive-5.0.0-darwin-arm64.zip` and move **Ferry Drive.app** to Applications. This release uses an Apple Development signature and is awaiting Apple notarization. |
| Windows 10 or 11 x64 | Run `ferry-drive-setup-5.0.0-amd64.exe`, or extract `ferry-drive-5.0.0-windows-amd64-portable.zip` and run **Ferry Drive.exe**. Web sign-in requires the Microsoft Edge WebView2 Runtime. |

Open the account menu and sign in on the provider’s web page. Select a drive to transfer files, and open Transfers to track progress.

On macOS, you can also install with Homebrew.

```sh
brew tap yjcdon/ferry-drive https://github.com/yjcdon/ferry-drive
brew install --cask yjcdon/ferry-drive/ferry-drive
```

If you installed `ferry-plus` from the old tap, run `brew update` and `brew migrate --cask yjcdon/ferry-plus/ferry-plus`, then run `brew upgrade --cask --greedy yjcdon/ferry-plus/ferry-drive`.

Download new versions from GitHub Releases and install them manually. Ferry Drive uses its own account and task data, so it can be installed alongside Ferry Plus 4.2.

## Development and license

[Technical design and release notes (Chinese)](docs/v5.0/architecture.md) · [Documentation (Chinese)](docs/README.md) · [Issues](https://github.com/yjcdon/ferry-drive/issues)

Based on [Ferry / BaiduPCS-Swift](https://github.com/yiquncode/BaiduPCS-Swift), with Baidu API usage informed by [BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go). Licensed under the [Apache License 2.0](LICENSE).

For the earlier macOS app, see [Ferry Plus 4.2.0](https://github.com/yjcdon/ferry-drive/releases/tag/v4.2.0).
