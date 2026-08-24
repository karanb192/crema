# Homebrew cask for Crema. Lives in the karanb192/homebrew-tap repo as
# Casks/crema.rb; kept here as the source of truth to copy on each release.
# Update `version` and `sha256` from `scripts/release.sh` output, then the
# release artifact URL resolves automatically.
cask "crema" do
  version "0.1.0"
  sha256 "49adcf4282ab77bec4851d8af7a259d114b3ee481e64fb08856354fd65be39da"

  url "https://github.com/karanb192/crema/releases/download/v#{version}/Crema-#{version}-arm64-mac.zip"
  name "Crema"
  desc "Keep your Mac awake while your AI coding agents are working"
  homepage "https://github.com/karanb192/crema"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64

  app "Crema.app"

  zap trash: [
    "~/Library/Preferences/in.karanbansal.crema.plist",
    "~/Library/Saved Application State/in.karanbansal.crema.savedState",
  ]
end
