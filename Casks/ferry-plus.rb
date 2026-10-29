cask "ferry-plus" do
  version "4.0"
  sha256 "fa556854775fee80bc75a47f2bc25dd425fc6f33048365a0e1b1cd524b4bcfd3"

  url "https://github.com/yjcdon/ferry-plus/releases/download/v#{version}/Ferry-Plus-#{version}-arm64.zip"
  name "Ferry Plus"
  desc "File transfer client for Baidu Netdisk and Quark Drive"
  homepage "https://github.com/yjcdon/ferry-plus"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Ferry Plus.app"
end
