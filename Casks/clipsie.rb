cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.7.2"
  sha256 arm:   "41b9fb7d4395ea1e14e5ec81983bb80f1e4b40d0dfa0ab7242637084d9b4de33",
         intel: "14aadd87f4679bec0c69197f3737ff8d7e73ec28b3379685416777f53b26ce95"

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
