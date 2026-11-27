cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.7.1"
  sha256 arm:   "0146f68b0490d913b5f50f093791ba7df1eb268ac9be6f938a05ca534b340d64",
         intel: "b872080fda828376998c53243ab0459bc98b4a1ff0851f1e9b523562e10b3ae1"

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
