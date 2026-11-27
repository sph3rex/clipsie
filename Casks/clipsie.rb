cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.7.0"
  sha256 arm:   "72546007c1c7bca4a920ae6473483be2a3f1b0a3e42bddd816ffa282b3069c3c",
         intel: "0e306316b73ce958636c0db8783611a0f91f140ba590039e15f53245765b3144"

  url "https://github.com/sph3rex/clipsie/releases/download/v#{version}/Clipsie-#{version}-#{arch}.zip"
  name "Clipsie"
  desc "A smart clipboard manager packed with goodies: history with search, tags, JavaScript commands and plugins"
  homepage "https://github.com/sph3rex/clipsie"

  depends_on macos: :ventura

  app "Clipsie.app"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Clipsie.app"], must_succeed: false
  end

  uninstall quit: "local.clipsie"

  zap trash: "~/Library/Application Support/Clipsie"
end
