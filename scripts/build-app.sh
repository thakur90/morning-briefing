#!/bin/zsh
# Builds Briefing.app without Xcode (design doc §2):
#   swift build → assemble bundle → codesign → optionally install to ~/Applications.
#
# Usage: scripts/build-app.sh [--debug] [--install]
# Env:   SIGN_IDENTITY  code-signing identity (default "-" = ad-hoc; see design doc A.6)
set -euo pipefail

cd "${0:A:h}/.."
config=release
install=false
for arg in "$@"; do
  case $arg in
    --debug) config=debug ;;
    --install) install=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
identity=${SIGN_IDENTITY:--}
bundle_id=com.thakur90.briefing

swift build -c $config --product briefing
bin_dir=$(swift build -c $config --show-bin-path)

app=.build/app/Briefing.app
rm -rf $app
mkdir -p $app/Contents/MacOS
cp $bin_dir/briefing $app/Contents/MacOS/briefing
cp Support/Info.plist $app/Contents/Info.plist
printf 'APPL????' > $app/Contents/PkgInfo

codesign --force --sign "$identity" --identifier $bundle_id $app
codesign --verify --strict $app
echo "Built $app (signed: $identity)"

if $install; then
  dest=~/Applications/Briefing.app
  mkdir -p ~/Applications
  rm -rf $dest
  cp -R $app $dest
  echo "Installed $dest"
fi
