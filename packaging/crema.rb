# Homebrew cask for Crema. Lives in the karanb192/homebrew-tap repo as
# Casks/crema.rb; kept here as the source of truth to copy on each release.
# Update `version` and `sha256` from `scripts/release.sh` output, then the
# release artifact URL resolves automatically.
cask "crema" do
  version "0.2.0"
  sha256 "2eb1c2824775958cae7a98601072cd9122a0304d788cb9a3d02a3c45b90dcd22"

  url "https://github.com/karanb192/crema/releases/download/v#{version}/Crema-#{version}-arm64-mac.zip"
  name "Crema"
  desc "Prevents the system from sleeping while AI coding agents are working"
  homepage "https://github.com/karanb192/crema"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Crema.app"

  zap trash: [
    "~/Library/Preferences/in.karanbansal.crema.plist",
    "~/Library/Saved Application State/in.karanbansal.crema.savedState",
  ]
end
