cask "ferry-plus" do
  version "4.1.4"
  sha256 "b41704f8bf6b20de33e328e5927e6dd0fa68a94d927c31fa27ec566902b35790"

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
