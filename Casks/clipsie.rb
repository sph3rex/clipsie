cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.2.0"
  sha256 arm:   "003469fb243f7b95be3a2df2de4daaea66a840a870c0affe4487636408ee3f4d",
         intel: "96a625ddcf7ec26fe7a90583f827717681520c0faaa9e3ca95319d5a39f7d94d"

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
