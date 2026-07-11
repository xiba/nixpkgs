{
  qtModule,
  qtbase,
  qtdeclarative,
  qtserialport,
  pkg-config,
  openssl,
  lib,
  stdenv,
  llvmPackages,
}:

qtModule {
  pname = "qtpositioning";
  propagatedBuildInputs = [
    qtbase
    qtdeclarative
    qtserialport
  ];
  nativeBuildInputs = [ pkg-config ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      # Apple's cctools ld64 (1010.6) hits an internal SIGTRAP (Trace/BPT trap: 5,
      # exit 133) when linking the CoreLocation position backend plugin
      # (libqtposition_cl.dylib, a -bundle -fapplication-extension Objective-C++
      # module linked against -framework CoreLocation). LLVM's ld64.lld does
      # not have this bug, so provide it and force the wrapped clang to use it
      # via NIX_CFLAGS_LINK below (same pattern as qtdeclarative/qtmultimedia).
      llvmPackages.lld
    ];
  buildInputs = [ openssl ];
  env = lib.optionalAttrs stdenv.hostPlatform.isDarwin {
    # TODO: Clean up on `staging`.
    NIX_CFLAGS_LINK = "-fuse-ld=lld";
  };
}
