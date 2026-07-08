{
  qtModule,
  qtdeclarative,
  qtwebchannel,
  qtpositioning,
  qtwebsockets,
  buildPackages,
  bison,
  coreutils,
  fetchpatch2,
  flex,
  gperf,
  ninja,
  pkg-config,
  python3,
  which,
  nodejs,
  nodejs_22,
  libxext,
  libxdamage,
  libxcomposite,
  xrandr,
  libxkbfile,
  libpciaccess,
  libxcursor,
  libxscrnsaver,
  libxrandr,
  libxtst,
  libxshmfence,
  libxi,
  cups,
  fontconfig,
  freetype,
  harfbuzz,
  icu,
  dbus,
  expat,
  libdrm,
  zlib,
  minizip,
  libjpeg,
  libpng,
  libtiff,
  libwebp,
  libopus,
  jsoncpp,
  protobuf,
  srtp,
  snappy,
  nss,
  libevent,
  openssl,
  alsa-lib,
  pulseaudio,
  libcap,
  pciutils,
  systemd,
  pipewire,
  gn,
  ffmpeg,
  lib,
  stdenv,
  glib,
  libxml2,
  libxslt,
  lcms2,
  libkrb5,
  libgbm,
  libva,
  enableProprietaryCodecs ? true,
  # darwin
  bootstrap_cmds,
  cctools,
  xcbuild,
  libresolv,
}:

qtModule {
  pname = "qtwebengine";
  nativeBuildInputs = [
    bison
    coreutils
    flex
    gperf
    ninja
    pkg-config
    (python3.withPackages (ps: with ps; [ html5lib ]))
    which
    gn
    # Node.js 24's new WASI file-descriptor tracking breaks Chromium's
    # devtools-frontend bundling step on Darwin, which runs rollup via
    # @rollup/wasm-node (fails with "EBADF: bad file descriptor"). Node.js 22
    # works, so it is pinned when the build host is Darwin.
    # TODO: drop this pin once the rollup/Node 24 WASI regression is resolved.
    (if stdenv.buildPlatform.isDarwin then nodejs_22 else nodejs)
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    bootstrap_cmds
    cctools
    xcbuild
  ];
  doCheck = true;
  outputs = [
    "out"
    "dev"
  ];

  dontUseGnConfigure = true;

  # ninja builds some components with -Wno-format,
  # which cannot be set at the same time as -Wformat-security
  hardeningDisable = [ "format" ];

  patches = [
    # Don't assume /usr/share/X11, and also respect the XKB_CONFIG_ROOT
    # environment variable, since NixOS relies on it working.
    # See https://github.com/NixOS/nixpkgs/issues/226484 for more context.
    ./xkb-includes.patch

    ./link-pulseaudio.patch

    # Override locales install path so they go to QtWebEngine's $out
    ./locales-path.patch

    # Reproducibility QTBUG-136068
    ./gn-object-sorted.patch
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    # Pass Nixpkgs' Darwin libc++, libresolv and compiler-rt paths into Chromium
    # GN, which drives an unwrapped clang that misses the cc-wrapper's setup.
    ./darwin-gn-toolchain-flags.patch

    # Strip relative --sysroot/-isysroot from generated Darwin link response
    # files so they don't override the correct absolute SDK. Upstreamable.
    ./darwin-strip-relative-sysroot.patch
  ];

  postPatch = ''
    # Patch Chromium build tools
    (
      cd src/3rdparty/chromium;

      # Manually fix unsupported shebangs
      substituteInPlace third_party/harfbuzz-ng/src/src/update-unicode-tables.make \
        --replace "/usr/bin/env -S make -f" "/usr/bin/make -f" || true
      substituteInPlace third_party/webgpu-cts/src/tools/run_deno \
        --replace "/usr/bin/env -S deno" "/usr/bin/deno" || true

      # On Darwin, patchShebangs hard-crashes on executable files that contain
      # only a shebang and do not end with a final newline, so add a trailing
      # newline to every executable first. See the same workaround in the
      # Chromium package (pkgs/applications/networking/browsers/chromium/common.nix).
      ${lib.optionalString stdenv.hostPlatform.isDarwin "find . -type f -perm -0100 -exec sed -i -e '$a\\' {} +"}

      patchShebangs .
    )

    substituteInPlace cmake/Functions.cmake \
      --replace "/bin/bash" "${buildPackages.bash}/bin/bash"

    # Patch library paths in sources
    substituteInPlace src/core/web_engine_library_info.cpp \
      --replace "QLibraryInfo::path(QLibraryInfo::DataPath)" "\"$out\"" \
      --replace "QLibraryInfo::path(QLibraryInfo::TranslationsPath)" "\"$out/translations\"" \
      --replace "QLibraryInfo::path(QLibraryInfo::LibraryExecutablesPath)" "\"$out/libexec\""

    substituteInPlace configure.cmake src/gn/CMakeLists.txt \
      --replace "AppleClang" "Clang"

    # Disable metal shader compilation, Xcode only
    substituteInPlace src/3rdparty/chromium/third_party/angle/src/libANGLE/renderer/metal/metal_backend.gni \
      --replace-fail 'angle_has_build && !is_ios && target_os == host_os' "false"
  ''
  + lib.optionalString stdenv.hostPlatform.isLinux ''
    sed -i -e '/lib_loader.*Load/s!"\(libudev\.so\)!"${lib.getLib systemd}/lib/\1!' \
      src/3rdparty/chromium/device/udev_linux/udev?_loader.cc

    sed -i -e '/libpci_loader.*Load/s!"\(libpci\.so\)!"${pciutils}/lib/\1!' \
      src/3rdparty/chromium/gpu/config/gpu_info_collector_linux.cc
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    substituteInPlace cmake/QtToolchainHelpers.cmake \
      --replace-fail "/usr/bin/xcrun" "${xcbuild}/bin/xcrun"

    # The Metal toolchain (shipped with Xcode) is unavailable in the Nix build
    # sandbox, which otherwise makes the "metal-toolchain" configure check fail
    # and disables the whole QtWebEngine build. Force the check to pass. This is
    # safe because nixpkgs also disables ANGLE Metal shader compilation, so this
    # configure check must not be relied upon to infer that metal/metallib are
    # actually available.
    substituteInPlace configure.cmake \
      --replace-fail "CONDITION NOT APPLE OR \''${TEST_metal_toolchain}" "CONDITION NOT APPLE OR TRUE"
  '';

  cmakeFlags = [
    "-DQT_FEATURE_qtpdf_build=ON"
    "-DQT_FEATURE_qtpdf_widgets_build=ON"
    "-DQT_FEATURE_qtpdf_quick_build=ON"
    "-DQT_FEATURE_pdf_v8=ON"
    "-DQT_FEATURE_pdf_xfa=ON"
    "-DQT_FEATURE_pdf_xfa_bmp=ON"
    "-DQT_FEATURE_pdf_xfa_gif=ON"
    "-DQT_FEATURE_pdf_xfa_png=ON"
    "-DQT_FEATURE_pdf_xfa_tiff=ON"
    "-DQT_FEATURE_webengine_system_libevent=ON"
    "-DQT_FEATURE_webengine_system_ffmpeg=ON"
    # android only. https://bugreports.qt.io/browse/QTBUG-100293
    # "-DQT_FEATURE_webengine_native_spellchecker=ON"
    "-DQT_FEATURE_webengine_sanitizer=ON"
    "-DQT_FEATURE_webengine_kerberos=ON"
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    "-DQT_FEATURE_webengine_system_libxml=ON"
    "-DQT_FEATURE_webengine_webrtc_pipewire=ON"

    # Appears not to work on some platforms
    # https://github.com/Homebrew/homebrew-core/issues/104008
    "-DQT_FEATURE_webengine_system_icu=ON"
  ]
  ++ lib.optionals enableProprietaryCodecs [
    "-DQT_FEATURE_webengine_proprietary_codecs=ON"
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0" # Per Qt 6’s deployment target (why doesn’t the hook work?)
    "-DQTWEBENGINE_NIX_LIBCXX_INCLUDE_DIR=${lib.getInclude stdenv.cc.libcxx}/include/c++/v1"
    "-DQTWEBENGINE_NIX_LIBCXX_LIBRARY_DIR=${lib.getLib stdenv.cc.libcxx}/lib"
    # Nixpkgs' Apple SDK ships resolv.h/libresolv in a separate package rather
    # than in the SDK, but Chromium's net stack (network_change_notifier_apple.mm)
    # includes <resolv.h> and links -lresolv. The GN build uses an unwrapped
    # clang with its own sysroot, so feed libresolv's paths in explicitly.
    "-DQTWEBENGINE_NIX_LIBRESOLV_INCLUDE_DIR=${lib.getDev libresolv}/include"
    "-DQTWEBENGINE_NIX_LIBRESOLV_LIBRARY_DIR=${lib.getLib libresolv}/lib"
    # Chromium's clang_base_path points at the unwrapped clang, so the GN link
    # step never picks up the compiler-rt builtins archive that the Nixpkgs cc
    # wrapper would normally supply via -resource-dir. Dawn's Metal backend and
    # Blink then fail to link (___divdc3, ___isPlatformVersionAtLeast). Feed the
    # builtins library directory in explicitly so the final link resolves them.
    # Sourced from stdenv.cc's own resource root to stay matched to the compiler.
    "-DQTWEBENGINE_NIX_COMPILER_RT_LIBRARY_DIR=${stdenv.cc}/resource-root/lib/darwin"
  ];

  propagatedBuildInputs = [
    qtdeclarative
    qtwebchannel
    qtwebsockets
    qtpositioning

    # Image formats
    libjpeg
    libpng
    libtiff
    libwebp

    # Video formats
    srtp

    # Audio formats
    libopus

    # Text rendering
    harfbuzz

    openssl
    glib
    libxslt
    lcms2

    libevent
    ffmpeg
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    dbus
    expat
    zlib
    minizip
    snappy
    nss
    protobuf
    jsoncpp

    icu
    libxml2

    # Audio formats
    alsa-lib
    pulseaudio

    # Text rendering
    fontconfig
    freetype

    libcap
    pciutils

    # X11 libs
    xrandr
    libxscrnsaver
    libxcursor
    libxrandr
    libpciaccess
    libxtst
    libxcomposite
    libxdamage
    libdrm
    libxkbfile
    libxshmfence
    libxi
    libxext

    # Pipewire
    pipewire

    libkrb5
    libgbm
    libva
  ];

  buildInputs = [
    cups
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    # Chromium's net stack links -lresolv; Nixpkgs' Apple SDK provides it here.
    libresolv
  ];

  requiredSystemFeatures = [ "big-parallel" ];

  preConfigure = ''
    export NINJAFLAGS="-j$NIX_BUILD_CORES"
  '';

  # Debug info is too big to link with LTO.
  separateDebugInfo = false;

  meta = {
    description = "Web engine based on the Chromium web browser";
    platforms = [
      "x86_64-darwin"
      "aarch64-darwin"
      "aarch64-linux"
      "armv7a-linux"
      "armv7l-linux"
      "x86_64-linux"
    ];
    # This build takes a long time; particularly on slow architectures
    # 1 hour on 32x3.6GHz -> maybe 12 hours on 4x2.4GHz
    timeout = 24 * 3600;
  };
}
