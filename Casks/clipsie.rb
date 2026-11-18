cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.5.0"
  sha256 arm:   "296cb6bdc834d1126282100cc1b251bfb039a5fbce72871375a71fbc6671e562",
         intel: "e7e6a9ecfcd298b2953eb42bb4812dc84f585be99155443e726c27f2b0127a24"

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
