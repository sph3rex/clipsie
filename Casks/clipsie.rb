cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.6.4"
  sha256 arm:   "9647713fbaf3892e6d1e5b437f65495e7d4aa2726e7ed109b6eea38ee62e2808",
         intel: "12753592a67b2db5d8f58baecf552a85e9a22c2c8c35810c144b50fc108b4ee0"

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
