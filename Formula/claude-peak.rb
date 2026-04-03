class ClaudePeak < Formula
  desc "Claude Max subscription usage monitor for macOS menu bar"
  homepage "https://github.com/letsur-dev/claude-peak"
  url "https://github.com/letsur-dev/claude-peak/archive/refs/tags/v1.4.5.tar.gz"
  sha256 "cf78a5a54e49d7833e6b6bd066960f216755931f1f0cba93a7a10971a220b435"
  license "MIT"

  bottle do
    root_url "https://github.com/letsur-dev/claude-peak/releases/download/v1.4.5"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "7c236038e88275619f7bf73bb35c739fb30cc9b038241073c3cd8244f0328ae3"
    sha256 cellar: :any_skip_relocation, arm64_tahoe: "b44a9d7757d5c2d1a00a77536dce2470ba1f1dcc27449f18a4be6a09da2c4ba7"
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
      APP="#{app_bundle}"
      DEST="$HOME/Applications/Claude Peak.app"
      osascript -e 'quit app "Claude Peak"' 2>/dev/null || true
      sleep 1
      mkdir -p "$HOME/Applications"
      rm -rf "$DEST" 2>/dev/null
      cp -R "$APP" "$DEST" 2>/dev/null
      open "${DEST:-$APP}"
    EOS
  end

  def post_install
    dest = File.expand_path("~/Applications/Claude Peak.app")
    src = prefix/"Claude Peak.app"
    return unless src.exist?
    FileUtils.mkdir_p(File.expand_path("~/Applications"))
    if File.exist?(dest)
      FileUtils.rm_rf(dest) rescue nil
    end
    FileUtils.cp_r(src.to_s, dest) rescue nil
  end

  def caveats
    <<~EOS
      To complete installation, run:
        claude-peak

      This copies the app to ~/Applications/ (for Spotlight/Raycast)
      and launches it. First launch requires OAuth login via browser.

      After `brew upgrade`, run `claude-peak` again to update the app.
    EOS
  end
end
