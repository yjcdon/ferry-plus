cask "ferry-plus" do
  version "4.2.0"
  sha256 "109ffc7296e0a809971a2009d64ad1839505ba04e5149baabe73458e44d3ce17"

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

  auto_updates true

  app "Ferry Plus.app"
end
