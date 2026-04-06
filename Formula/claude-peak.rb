class ClaudePeak < Formula
  desc "Claude Max subscription usage monitor for macOS menu bar"
  homepage "https://github.com/letsur-dev/claude-peak"
  url "https://github.com/letsur-dev/claude-peak/archive/refs/tags/v1.4.7.tar.gz"
  sha256 "1a1c8e2e41936cd97ffe4e925a012fc0dee763bcb0dc322a46c8dde640a64fa4"
  license "MIT"

  bottle do
    root_url "https://github.com/letsur-dev/claude-peak/releases/download/v1.4.7"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "611b0ecb1d98d12348640a0a01ddf58fcd9e9cfa66affc683ce412fa38dce46a"
    sha256 cellar: :any_skip_relocation, arm64_tahoe: "4bbc1bd851cd8e028a77f7f35aa6bcb5c57273d3f0a9ddd63fe8b36a47de6f8c"
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
