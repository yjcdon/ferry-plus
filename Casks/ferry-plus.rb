cask "ferry-plus" do
  version "4.1.1"
  sha256 "beff752631f86905508b7b6e861186dc9ac550c79d6037edb8af45bcb1c98a8d"

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
