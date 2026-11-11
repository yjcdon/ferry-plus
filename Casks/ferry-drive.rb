cask "ferry-drive" do
  version "5.0.0"
  sha256 "0b649f6ec84f509da321b0a97b2526d4be25798bf99007f3c6ca3c4473434a4a"

  url "https://github.com/yjcdon/ferry-drive/releases/download/v#{version}/ferry-drive-#{version}-darwin-arm64.tar.gz"
  name "Ferry Drive"
  desc "File transfer client for Baidu Netdisk and Quark Drive"
  homepage "https://github.com/yjcdon/ferry-drive"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  auto_updates true

  app "Ferry Drive.app"
end
