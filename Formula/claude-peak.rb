class ClaudePeak < Formula
  desc "Claude Max subscription usage monitor for macOS menu bar"
  homepage "https://github.com/letsur-dev/claude-peak"
  url "https://github.com/letsur-dev/claude-peak/archive/refs/tags/v1.3.7.tar.gz"
  sha256 "52ec72f8723c74b456e58ad8a3a6858a0a74581e25df6a23a1e75cf9208b9141"
  license "MIT"

  bottle do
    root_url "https://github.com/letsur-dev/claude-peak/releases/download/v1.3.7"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "05633bcf7cf5fd731ed542988b15b1ea05ed7427d12a91c852ed28e6ace7cbe6"
    sha256 cellar: :any_skip_relocation, arm64_tahoe: "31acdf61393bad76f8b02e01b3508bb01f2b8f5a74d405bc0da048fb357a3245"
  end





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
      osascript -e 'quit app "Claude Peak"' 2>/dev/null || true
      sleep 1
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
