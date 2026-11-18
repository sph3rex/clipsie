cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.6.0"
  sha256 arm:   "91df794ea21f2cca3f7f8c0a12c9623e18efa3aa81f7cb7e14f5d3feea63c8b8",
         intel: "2977db8c5d3707ba6e41960d77cf57f7bba222888526a738c2bd434f77f2591a"

  url "https://github.com/sph3rex/clipsie/releases/download/v#{version}/Clipsie-#{version}-#{arch}.zip"
  name "Clipsie"
  desc "A smart clipboard manager packed with goodies: history with search, tags, JavaScript commands and plugins"
  homepage "https://github.com/sph3rex/clipsie"

  depends_on macos: ">= :ventura"

  app "Clipsie.app"

  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Clipsie.app"]
  end

  uninstall quit: "local.clipsie"

  zap trash: "~/Library/Application Support/Clipsie"
end
