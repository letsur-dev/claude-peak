class ClaudePeak < Formula
  desc "Claude Max subscription usage monitor for macOS menu bar"
  homepage "https://github.com/letsur-dev/claude-peak"
  url "https://github.com/letsur-dev/claude-peak/archive/refs/tags/v1.3.5.tar.gz"
  sha256 "db3123b38a1e0a153a66252b16e6d14316873b973f07703e851e3b5d96005380"
  license "MIT"

  bottle do
    root_url "https://github.com/letsur-dev/claude-peak/releases/download/v1.3.5"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "f1e15762ac757a88d42ab3b3f1bce72c88ff521ae18ea506f0577f5a64f724ae"
    sha256 cellar: :any_skip_relocation, arm64_tahoe: "b1ac4c2bf03ff2dad1a35c071b62741f986e4fdc7b051eaa63ed2b5ac76d18e4"
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

    # Create a launcher script in bin/
    (bin/"claude-peak").write <<~EOS
      #!/bin/bash
      APP="#{app_bundle}"
      LINK="$HOME/Applications/Claude Peak.app"
      if [ ! -L "$LINK" ] || [ "$(readlink "$LINK")" != "$APP" ]; then
        mkdir -p "$HOME/Applications"
        rm -rf "$LINK"
        ln -sf "$APP" "$LINK"
      fi
      open "$APP"
    EOS
  end

  def caveats
    <<~EOS
      Run `claude-peak` to launch (auto-links to ~/Applications/ on first run).
      Or directly: open "#{prefix}/Claude Peak.app"

      First launch requires OAuth login via browser.
    EOS
  end
end
