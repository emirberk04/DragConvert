#!/bin/zsh
# FFmpeg'i ve kullandığı codec kütüphanelerini kaynaktan derler (Homebrew yok).
#
#   scripts/build-ffmpeg.sh          → Vendor/ffmpeg/bin/{ffmpeg,ffprobe,libav*.dylib} (derleme /tmp/dragconvert-ffmpeg içinde)
#   CLEAN=1 scripts/build-ffmpeg.sh  → önce derleme klasörlerini siler (indirilenler kalır)
#
# Kişisel kullanım: dağıtılmadığı için lisans sınırlaması yok, ama GPL'e de gerek yok (x264 yerine VideoToolbox).
# Codec kütüphaneleri (lame, webp, vpx, opus) libavcodec'e statik gömülü; dışarıya sadece sistem kütüphaneleri.
#
# Kaynakların SHA-256'ları scripts/ffmpeg-sources.sha256'da. Bir dosya orada yoksa ilk indirmede kaydedilir
# (ilk güven), sonraki her indirmede doğrulanır; uyuşmazsa derleme durur.
set -euo pipefail

ROOT=${0:A:h:h}
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/src"          # indirilen arşivler
# ffmpeg configure satırını (yolları dahil) ikili dosyalara gömer ve `ffmpeg -version` bunu gösterir. Dağıtılan
# dosyada kullanıcı adı/klasör yolu olmasın diye derleme kişisel olmayan sabit bir yolda yapılır, sonuç kopyalanır.
WORK="${DRAGCONVERT_BUILD_DIR:-/tmp/dragconvert-ffmpeg}"
BUILD="$WORK/build"        # açılan kaynaklar
DEPS="$WORK/deps"          # statik codec kütüphaneleri + pkgconf
OUT="$WORK/ffmpeg"         # bin/ffmpeg, bin/ffprobe, libav*.dylib
FINAL="$VENDOR/ffmpeg"
SUMS="$ROOT/scripts/ffmpeg-sources.sha256"
JOBS=$(sysctl -n hw.ncpu)

export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
export PATH="$DEPS/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"

FFMPEG=9.0.2
PKGCONF=3.0.10
LAME=3.100
WEBP=1.6.0
VPX=1.17.0
OPUS=1.5.2

typeset -A URLS
URLS=(
  ffmpeg-$FFMPEG.tar.xz   https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz
  pkgconf-$PKGCONF.tar.xz https://distfiles.ariadne.space/pkgconf/pkgconf-$PKGCONF.tar.xz
  lame-$LAME.tar.gz       https://downloads.sourceforge.net/project/lame/lame/$LAME/lame-$LAME.tar.gz
  libwebp-$WEBP.tar.gz    https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP.tar.gz
  libvpx-$VPX.tar.gz      https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX.tar.gz
  opus-$OPUS.tar.gz       https://github.com/xiph/opus/releases/download/v$OPUS/opus-$OPUS.tar.gz
)

step() { print -P "%F{cyan}==> $*%f" }

fetch() {
  local name=$1 file="$SRC/$1"
  [[ -f "$file" ]] || { step "İndiriliyor: $name"; curl -fL --retry 3 -o "$file.part" "${URLS[$name]}"; mv "$file.part" "$file"; }
  local actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
  local expected=$(grep " $name\$" "$SUMS" 2>/dev/null | cut -d' ' -f1 || true)
  if [[ -z "$expected" ]]; then
    print "$actual $name" >> "$SUMS"
    print -P "%F{yellow}   $name ilk kez görüldü, SHA-256 kaydedildi: $actual%f"
  elif [[ "$expected" != "$actual" ]]; then
    print -P "%F{red}   $name SHA-256 uyuşmuyor!\n   beklenen $expected\n   bulunan  $actual%f"
    exit 1
  fi
}

unpack() {  # unpack <arşiv> <klasör adı> → $BUILD/<klasör adı>
  rm -rf "$BUILD/$2"
  mkdir -p "$BUILD/$2"
  tar -xf "$SRC/$1" -C "$BUILD/$2" --strip-components 1
}

autotools() {  # autotools <arşiv> <klasör> [configure argümanları...]
  local archive=$1 dir=$2; shift 2
  step "Derleniyor: $dir"
  unpack "$archive" "$dir"
  ( cd "$BUILD/$dir" && ./configure --prefix="$DEPS" --disable-shared --enable-static "$@" >/dev/null \
      && make -j"$JOBS" >/dev/null && make install >/dev/null )
}

[[ -n "${CLEAN:-}" ]] && rm -rf "$WORK"
mkdir -p "$SRC" "$BUILD" "$DEPS" "$OUT"
touch "$SUMS"
for name in ${(k)URLS}; do fetch "$name"; done

# pkg-config: ffmpeg codec kütüphanelerini onunla bulur ve sistemde yok.
if [[ ! -x "$DEPS/bin/pkgconf" ]]; then
  step "Derleniyor: pkgconf"
  unpack pkgconf-$PKGCONF.tar.xz pkgconf
  ( cd "$BUILD/pkgconf" && ./configure --prefix="$DEPS" --disable-shared >/dev/null \
      && make -j"$JOBS" >/dev/null && make install >/dev/null )
fi

if [[ ! -f "$DEPS/lib/libmp3lame.a" ]]; then
  step "Derleniyor: lame"
  unpack lame-$LAME.tar.gz lame
  # 3.100'ün sembol listesinde var olmayan bir fonksiyon var; yeni bağlayıcı bunu hata sayıyor.
  sed -i '' '/lame_init_old/d' "$BUILD/lame/include/libmp3lame.sym"
  ( cd "$BUILD/lame" && ./configure --prefix="$DEPS" --disable-shared --enable-static \
      --disable-frontend --disable-decoder >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null )
fi

[[ -f "$DEPS/lib/libwebp.a" ]] || autotools libwebp-$WEBP.tar.gz libwebp \
  --enable-libwebpmux --disable-libwebpdecoder --disable-gl --disable-sdl --disable-png --disable-jpeg \
  --disable-tiff --disable-gif --disable-wic

[[ -f "$DEPS/lib/libopus.a" ]] || autotools opus-$OPUS.tar.gz opus --disable-doc --disable-extra-programs

if [[ ! -f "$DEPS/lib/libvpx.a" ]]; then
  step "Derleniyor: libvpx"
  unpack libvpx-$VPX.tar.gz libvpx
  # libvpx kendi configure'ını kullanır; macOS 27 hedefini tanımayabilir, en yeni bildiği darwin hedefi seçilir.
  # `configure --help` sıfır olmayan kodla çıkar; pipefail altında `|| true` gerekli.
  target=$(cd "$BUILD/libvpx" && { ./configure --help || true; } | grep -oE 'arm64-darwin[0-9]+-gcc' | sort -V | tail -1)
  ( cd "$BUILD/libvpx" && ./configure --prefix="$DEPS" --target="$target" --disable-shared --enable-static \
      --enable-pic --enable-vp9-highbitdepth --disable-examples --disable-tools --disable-docs \
      --disable-unit-tests >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null )
fi

# Boyut için sadece DragConvert'in kullandıkları (bkz. FFmpegArguments, MediaTools). Her girdi okunabilsin diye bütün
# çözücüler ve demuxer'lar açık; kodlayıcı, muxer ve filtreler seçili. mpeg4 kodlayıcısı ile testsrc/sine
# filtreleri testlerin örnek dosyaları için. Yeni bir hedef eklenince buraya da eklenmeli.
ENCODERS=png,mjpeg,h264_videotoolbox,hevc_videotoolbox,aac_at,aac,libmp3lame,libopus,libvpx_vp9,libwebp,gif,flac,pcm_s16le,pcm_s16be,mpeg4
MUXERS=mp4,mov,ipod,matroska,webm,gif,mp3,wav,aiff,flac,ogg,opus,adts,segment,webp,image2,null
FILTERS=buffer,buffersink,abuffer,abuffersink,scale,format,aformat,aresample,null,anull,crop,transpose,hflip,vflip,rotate,fps,split,palettegen,paletteuse,loudnorm,setpts,asetpts,trim,atrim,testsrc,sine

step "Derleniyor: ffmpeg $FFMPEG (birkaç dakika)"
unpack ffmpeg-$FFMPEG.tar.xz ffmpeg
(
  cd "$BUILD/ffmpeg"
  ./configure --prefix="$OUT" --cc=clang --arch=arm64 \
    --pkg-config="$DEPS/bin/pkgconf" --pkg-config-flags=--static \
    --extra-cflags="-I$DEPS/include $CFLAGS" --extra-ldflags="-L$DEPS/lib $LDFLAGS" \
    --enable-shared --disable-static --libdir="$OUT/bin" --install-name-dir=@executable_path \
    --disable-debug --disable-doc --disable-ffplay \
    --disable-network --disable-everything \
    --enable-decoders --enable-demuxers --enable-parsers --enable-bsfs \
    --enable-protocol=file,pipe \
    --enable-encoder="$ENCODERS" --enable-muxer="$MUXERS" --enable-filter="$FILTERS" \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-libmp3lame --enable-libwebp --enable-libvpx --enable-libopus >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
)

# ffmpeg ve ffprobe aynı libav* kütüphanelerini paylaşır (statik olsa iki kez yer kaplardı); dylib'ler
# programların yanında, kurulum adı @executable_path. Başlıklar ve pkg-config dosyaları uygulamaya girmez.
rm -rf "$OUT/include" "$OUT/lib" "$OUT/share" "$OUT/bin/pkgconfig"
strip "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe"
for lib in "$OUT"/bin/*.dylib(N); do [[ -L "$lib" ]] || strip -x "$lib"; done

rm -rf "$FINAL" && mkdir -p "$FINAL" && cp -R "$OUT/bin" "$FINAL/"
step "Hazır"
ls -lh "$FINAL/bin"
otool -L "$FINAL/bin/ffmpeg" | tail -n +2
