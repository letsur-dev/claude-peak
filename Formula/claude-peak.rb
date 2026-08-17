class ClaudePeak < Formula
  desc "Claude Max subscription usage monitor for macOS menu bar"
  homepage "https://github.com/letsur-dev/claude-peak"
  url "https://github.com/letsur-dev/claude-peak/archive/refs/tags/v1.6.2.tar.gz"
  sha256 "520b215fc4de0e710b69276405414dc99ee0c0bdb8dc024fc3017f1ee959d27e"
  license "MIT"

  bottle do
    root_url "https://github.com/letsur-dev/claude-peak/releases/download/v1.6.2"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "23bbb4bc45d8a626fd06c57a87d455645f938d74eb21a1bd629927d381737e51"
    sha256 cellar: :any_skip_relocation, arm64_tahoe: "fed1d8364e6d032c9e90854917d6e327616ec87374857cf9bbe3ece3a05d7b7e"
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
