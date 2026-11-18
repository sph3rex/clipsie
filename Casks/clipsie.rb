cask "clipsie" do
  arch arm: "arm64", intel: "x86_64"

  version "0.6.1"
  sha256 arm:   "5b8454e73f80155a52dd88ba5402a747411bd530cdef6a2cf26e41dbe296259e",
         intel: "7bc175339e52b013e04193e91b38ad21c8da2aaba49b5bd6bb13f6d3f4a5702e"

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
