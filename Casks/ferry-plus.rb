cask "ferry-plus" do
  version "3.1"
  sha256 "b96cc05b317e1e693f99ca8a60d6829e13f7b86041ecdd45ccebcc157a1362e8"

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
