cask "accio" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/amantibrewal310/Accio/releases/download/v#{version}/Accio-#{version}.zip"
  name "Accio"
  desc "Menu bar manager that hides items and brings them back on demand"
  homepage "https://github.com/amantibrewal310/Accio"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Accio.app"

  uninstall quit: "com.accio.app"

  zap trash: "~/Library/Preferences/com.accio.app.plist"

  caveats <<~EOS
    Accio isn't notarized by Apple, so macOS blocks its first launch:
      1. Open Accio from Applications.
      2. In System Settings → Privacy & Security, click "Open Anyway".
    Accio then asks for Accessibility access, which it uses to see and arrange
    your menu bar items.
  EOS
end
