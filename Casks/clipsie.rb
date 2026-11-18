cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.6.2"
  sha256 arm:   "c6b2c7f7ab85eb52ae0052672e1a456b317d23f4e14dea8c5056e7fd7d2e2a10",
         intel: "4566b8f7c1dcc7c1e02913ebf803244584d118f901278519efa190503b3834f2"

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
