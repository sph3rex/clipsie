cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.3.0"
  sha256 arm:   "c684ee2d2bebdfd6641224f6e16864395dcbc8cd189992c6830989e6f564b826",
         intel: "423a11efbfbfbfa61f960be1df3897e29f04b94bbd12dc1f1d2598de3e314885"

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
