class ClaudePeak < Formula
  desc "Claude Max subscription usage monitor for macOS menu bar"
  homepage "https://github.com/letsur-dev/claude-peak"
  url "https://github.com/letsur-dev/claude-peak/archive/refs/tags/v1.3.8.tar.gz"
  sha256 "52d43fe0092d425160e79d5c864339c373949e3ec733812aa7820c7dc5b710f6"
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
      osascript -e 'quit app "Claude Peak"' 2>/dev/null || true
      sleep 1
      DEST="$HOME/Applications/Claude Peak.app"
      if [ -e "$DEST" ]; then
        osascript -e "tell application \\"Finder\\" to delete POSIX file \\"$DEST\\"" 2>/dev/null || rm -rf "$DEST"
      fi
      mkdir -p "$HOME/Applications"
      cp -R "#{app_bundle}" "$DEST"
      open "$DEST"
    EOS
  end

  def post_install
    system "bash", "-c", <<~EOS
      osascript -e 'quit app "Claude Peak"' 2>/dev/null || true
      sleep 1
      DEST="$HOME/Applications/Claude Peak.app"
      if [ -e "$DEST" ]; then
        osascript -e "tell application \\"Finder\\" to delete POSIX file \\"$DEST\\"" 2>/dev/null || rm -rf "$DEST"
      fi
      mkdir -p "$HOME/Applications"
      cp -R "#{prefix}/Claude Peak.app" "$DEST"
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
