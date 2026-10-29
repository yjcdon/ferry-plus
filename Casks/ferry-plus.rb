cask "ferry-plus" do
  version "4.1.2"
  sha256 "63df1169545a6f62bbb8f707975e5001620d909054c0ed1aae34aa2b55909461"

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
