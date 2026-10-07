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

  # Accio isn't notarized (no paid Apple developer account), so Gatekeeper
  # would refuse to open it, saying it can't check it for malware. Installing
  # with Homebrew is the user's go-ahead, so lift the download quarantine.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Accio.app"],
        writable_paths: ["{{appdir}}/Accio.app"]
  end

  uninstall quit: "com.accio.app"

  zap trash: "~/Library/Preferences/com.accio.app.plist"

  caveats <<~EOS
    Accio asks for Accessibility access on first launch, which it uses to see
    and arrange your menu bar items.
  EOS
end
