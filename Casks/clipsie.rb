cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.6.3"
  sha256 arm:   "fce0c0f9aaef414803eee1dc7e10f1c898d31566b77ef593836aafe24c8fbdc0",
         intel: "af506d2882d316aaa09e13124c2befff46c1519c5141ed651216c1712ac6b3d0"

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
