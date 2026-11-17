cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.4.0"
  sha256 arm:   "2920eeb6ec40652dc3b8ebacd47371e25102327afe1639f2cd832657334c7cf2",
         intel: "95023ced5ed4373b23c853603ecbbc0c8cef3e21a67ace0d22c07791ea65670e"

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
