cask "ferry-drive" do
  version "5.0.0"
  sha256 "647b951aa03d675bea166391220b2e52219c37e3c141b3558d449846bb974653"

  url "https://github.com/yjcdon/ferry-drive/releases/download/v#{version}/ferry-drive-#{version}-darwin-arm64.zip"
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
