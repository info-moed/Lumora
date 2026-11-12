# Homebrew formula for Lumora. Builds the app on your Mac from source (so it needs no notarization) and installs
# the encoders it drives.
#
#   brew tap info-moed/lumora https://github.com/info-moed/Lumora
#   brew install --HEAD lumora
class Lumora < Formula
  desc "Grade and convert video between SDR and HDR, with frame interpolation"
  homepage "https://info-moed.github.io/Lumora/"
  license "MIT"
  head "https://github.com/info-moed/Lumora.git", branch: "main"

  depends_on xcode: ["27.0", :build]
  depends_on "xcodegen" => :build
  depends_on "aom"
  depends_on arch: :arm64
  depends_on "ffmpeg"
  depends_on "libvmaf"
  depends_on macos: :golden_gate
  depends_on "svt-av1"
  depends_on "x265"

  def install
    system "xcodegen", "generate"
    xcodebuild "-project", "Lumora.xcodeproj", "-scheme", "Lumora", "-configuration", "Release",
           "-derivedDataPath", buildpath/"build", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO",
           # Homebrew builds inside a sandbox; the Swift compiler's own sandbox for macro plugins can't nest in it.
           "OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox", "build"
    prefix.install buildpath/"build/Build/Products/Release/Lumora.app"
    (bin/"lumora").write <<~SH
      #!/bin/bash
      # Opens Lumora; any arguments are files to open.
      exec /usr/bin/open -a "#{opt_prefix}/Lumora.app" "$@"
    SH
  end

  def caveats
    <<~EOS
      Lumora.app is in #{opt_prefix}. Add it to Applications (and Launchpad/Spotlight) with:
        ln -sf "#{opt_prefix}/Lumora.app" /Applications/Lumora.app
      or start it from Terminal with:
        lumora

      Optional extras for H.266/VVC, Dolby Vision and HDR10+ metadata:
        brew install vvenc gpac mkvtoolnix dovi_tool hdr10plus_tool
    EOS
  end

  test do
    app = prefix/"Lumora.app"
    assert_predicate app/"Contents/MacOS/Lumora", :executable?
    assert_path_exists app/"Contents/Resources/default.metallib"
    system "/usr/bin/codesign", "--verify", "--deep", app
  end
end
