cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000",
         intel: "0000000000000000000000000000000000000000000000000000000000000000"

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
