#!/usr/bin/env bash
# Rebuild Hermes' prebuilt libavcodec with the VAAPI intra-refresh patch.
#   bash build-intra-refresh-ffmpeg.sh ~/hermes-touch
# Leaves a copy of the prebuilt FFmpeg, with the patched libavcodec.a, in
# ~/hermes-ffmpeg/dist, for -DFFMPEG_PREPARED_BINARIES. The original stays as it is.
set -eu
src="${1:?path to the Hermes checkout}"
orig="$src/third-party/build-deps/dist/Linux-x86_64"
work="$HOME/hermes-ffmpeg"
here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$orig/lib/libavcodec.a" ] || { echo "no prebuilt FFmpeg at $orig"; exit 1; }
version="$(sed -n 's/.*FFMPEG_VERSION "\(.*\)".*/\1/p' "$orig/include/libavutil/ffversion.h")"
case "$version" in
  6400860*) commit=6400860b9d4bec5ace91ec3a5e43ad76f9660579; patch="$here/vaapi-intra-refresh-7.1.patch" ;;
  *) echo "prebuilt FFmpeg is $version; this script knows 6400860 (7.1) only"; exit 1 ;;
esac

mkdir -p "$work"
rm -rf "$work/dist" "$work/pc"
cp -r "$orig" "$work/dist"
mkdir "$work/pc"
for f in "$orig"/lib/pkgconfig/*.pc; do sed "s|^prefix=.*|prefix=$orig|" "$f" > "$work/pc/$(basename "$f")"; done
printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\nName: x264\nDescription: x264\nVersion: 0.165.0\nLibs: -L${libdir} -lx264\nLibs.private: -lpthread -lm -ldl\nCflags: -I${includedir}\n' "$orig" > "$work/pc/x264.pc"
printf 'prefix=%s\nincludedir=${prefix}/include\nName: ffnvcodec\nDescription: FFmpeg NVIDIA headers\nVersion: 12.2.72.0\nCflags: -I${includedir}\n' "$orig" > "$work/pc/ffnvcodec.pc"

if [ ! -d "$work/FFmpeg/.git" ]; then
  git init -q "$work/FFmpeg"
fi
cd "$work/FFmpeg"
git fetch -q --depth 1 https://github.com/FFmpeg/FFmpeg "$commit"
git checkout -q -f FETCH_HEAD
git clean -qfdx
git apply "$patch"
asm=""
command -v nasm >/dev/null || asm="--disable-x86asm"
PKG_CONFIG_PATH="$work/pc" ./configure --pkg-config-flags=--static \
  --extra-cflags="-w -I$orig/include" --extra-ldflags="-L$orig/lib" --extra-libs='-lpthread -lm' \
  --disable-all --disable-autodetect --disable-iconv --enable-gpl --enable-static \
  --enable-avcodec --enable-avutil --enable-bsfs --enable-swscale \
  --enable-amf --enable-encoder=h264_amf,hevc_amf,av1_amf \
  --enable-cuda --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc --enable-ffnvcodec --enable-nvenc \
  --enable-libsvtav1 --enable-encoder=libsvtav1 \
  --enable-vaapi --enable-encoder=h264_vaapi,hevc_vaapi,av1_vaapi \
  --enable-libx264 --enable-encoder=libx264 --enable-libx265 --enable-encoder=libx265 \
  --enable-encoder=h264_v4l2m2m --enable-v4l2_m2m $asm > "$work/configure.log" 2>&1 ||
  { tail -5 "$work/configure.log"; exit 1; }
make -j"$(nproc)" libavcodec/libavcodec.a > "$work/make.log" 2>&1 || { tail -20 "$work/make.log"; exit 1; }
cp libavcodec/libavcodec.a "$work/dist/lib/libavcodec.a"
grep -qa "Rolling intra refresh" "$work/dist/lib/libavcodec.a" || { echo "the patched code is missing from libavcodec.a"; exit 1; }
echo "patched FFmpeg ready: $work/dist"
