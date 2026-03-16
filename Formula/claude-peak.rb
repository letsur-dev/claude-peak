class ClaudePeak < Formula
  desc "Claude Max subscription usage monitor for macOS menu bar"
  homepage "https://github.com/letsur-dev/claude-peak"
  url "https://github.com/letsur-dev/claude-peak/archive/refs/tags/v1.3.5.tar.gz"
  sha256 "db3123b38a1e0a153a66252b16e6d14316873b973f07703e851e3b5d96005380"
  license "MIT"





  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    app_name = "Claude Peak"
    app_bundle = prefix/"#{app_name}.app"

    (app_bundle/"Contents/MacOS").mkpath
    (app_bundle/"Contents/Resources").mkpath
    cp buildpath/".build/release/ClaudePeak", app_bundle/"Contents/MacOS/ClaudePeak"
    cp buildpath/"Resources/Info.plist", app_bundle/"Contents/Info.plist"
    cp buildpath/"Resources/AppIcon.icns", app_bundle/"Contents/Resources/AppIcon.icns"

    # Create a launcher script in bin/
    (bin/"claude-peak").write <<~EOS
      #!/bin/bash
      APP="#{app_bundle}"
      DEST="$HOME/Applications/Claude Peak.app"
      mkdir -p "$HOME/Applications"
      rm -rf "$DEST"
      cp -R "$APP" "$DEST"
      open "$DEST"
    EOS
  end

  def post_install
    system "bash", "-c", <<~EOS
      APP="#{prefix}/Claude Peak.app"
      DEST="$HOME/Applications/Claude Peak.app"
      mkdir -p "$HOME/Applications"
      rm -rf "$DEST"
      cp -R "$APP" "$DEST"
    EOS
  end

  def caveats
    <<~EOS
      Claude Peak has been installed to ~/Applications/.
      Open from Spotlight, Raycast, or run `claude-peak`.

      First launch requires OAuth login via browser.
    EOS
  end
end
