#!/bin/sh
# Packages flutter build linux --release into a .deb and a portable tarball,
# for this machine's processor (x64 or arm64), as Baogong (包工头), this fork:
# package baogong in /opt/baogong, beside upstream's baocode. Run on Ubuntu after the
# bundle exists at build/linux/<arch>/release/bundle. The remote server's
# VERSION and servers.json, when built into build/remote/, go beside the
# executable (lib/remote/remote_binaries.dart); the app downloads the
# builds they name.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^version:[[:space:]]*//p' "$root/pubspec.yaml")
marketing=${version%%+*}
case "$(uname -m)" in
  x86_64) arch=x64; package_arch=amd64 ;;
  aarch64 | arm64) arch=arm64; package_arch=arm64 ;;
  *) echo "Not built for $(uname -m)" >&2; exit 1 ;;
esac
bundle="$root/build/linux/$arch/release/bundle"

if [ ! -x "$bundle/baocode" ]; then
  echo "No bundle at $bundle. Run: flutter build linux --release" >&2
  exit 1
fi

if [ -f "$root/build/remote/servers.json" ]; then
  rm -rf "$bundle/remote"
  mkdir -p "$bundle/remote"
  cp "$root/build/remote/VERSION" "$root/build/remote/servers.json" "$bundle/remote/"
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/opt/baogong" \
  "$stage/usr/bin" \
  "$stage/usr/share/applications" \
  "$stage/usr/share/icons/hicolor/128x128/apps" \
  "$stage/DEBIAN"

cp -a "$bundle/." "$stage/opt/baogong/"
cp "$root/assets/branding/app_icon.png" \
  "$stage/usr/share/icons/hicolor/128x128/apps/baogong.png"

cat > "$stage/usr/bin/baogong" << 'EOF'
#!/bin/sh
exec /opt/baogong/baocode "$@"
EOF
chmod 755 "$stage/usr/bin/baogong"

cat > "$stage/usr/share/applications/baogong.desktop" << 'EOF'
[Desktop Entry]
Name=Baogong
Name[zh_CN]=包工头
Comment=Desktop app for Claude Code
Exec=baogong %U
Icon=baogong
Terminal=false
Type=Application
Categories=Development;
StartupWMClass=dev.baocode.desktop
EOF

# libgtk-3-0 is what the engine links. libblkid1 and liblzma5 are the
# extra libraries Flutter's Linux bundle expects on the system.
cat > "$stage/DEBIAN/control" << EOF
Package: baogong
Version: ${marketing}
Section: devel
Priority: optional
Architecture: ${package_arch}
Depends: libgtk-3-0, libblkid1, liblzma5
Maintainer: y0un922 <y0un92@linux.do>
Homepage: https://github.com/y0un922/baogong
Description: Baogong (包工头), an unofficial fork of BaoCode
 A desktop UI for Claude Code, with a fast IDE built in.
EOF

out="$root/build/installers"
mkdir -p "$out"
dpkg-deb --build --root-owner-group "$stage" \
  "$out/Baogong-${marketing}-linux-${package_arch}.deb"
tar -C "$bundle" -czf "$out/Baogong-${marketing}-linux-${package_arch}.tar.gz" .
echo "Wrote $out/Baogong-${marketing}-linux-${package_arch}.deb"
echo "Wrote $out/Baogong-${marketing}-linux-${package_arch}.tar.gz"
