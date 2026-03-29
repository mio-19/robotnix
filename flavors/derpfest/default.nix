# SPDX-FileCopyrightText: 2026 robotnix contributors
# SPDX-License-Identifier: MIT

{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib)
    attrNames
    filterAttrs
    filter
    listToAttrs
    mapAttrs'
    mkDefault
    mkIf
    nameValuePair
    optionals
    hasPrefix
    ;

  derpfestBranchToAndroidVersion = {
    "16" = 16;
    "16.2" = 16;
  };

  deviceMetadata = lib.importJSON ../lineageos/devices.json;
  supportedDevices = attrNames deviceMetadata;
  sourceMetadata = lib.importJSON ./sources.generated.json;
  lineageLockEntries = (lib.importJSON ../lineageos/lineage-23.0/repo.lock).entries;

  enchiladaDevicePaths = [
    "device/oneplus/enchilada"
    "device/oneplus/sdm845-common"
    "hardware/oneplus"
    "kernel/oneplus/sdm845"
    "vendor/oneplus/enchilada"
    "vendor/oneplus/sdm845-common"
  ];

  fetchSource =
    entry:
    if entry.type == "github" then
      pkgs.fetchFromGitHub {
        inherit (entry) owner repo rev;
        sha256 = entry.sha256;
      }
    else if entry.type == "gitlab" then
      pkgs.fetchzip {
        url = "https://gitlab.com/${entry.owner}/${entry.repo}/-/archive/${entry.rev}/${entry.repo}-${entry.rev}.tar.gz";
        sha256 = entry.sha256;
      }
    else
      throw "Unsupported derpfest source type `${entry.type}` for `${entry.path}`";

  mkSourceDirs =
    entries:
    listToAttrs (builtins.map (entry: nameValuePair entry.path { src = fetchSource entry; }) entries);

  derpfestSources = mkSourceDirs (
    filter (entry: !(builtins.elem entry.path enchiladaDevicePaths)) sourceMetadata
  );

  enchiladaSources = lib.optionalAttrs (config.device == "enchilada") (
    mkSourceDirs (filter (entry: builtins.elem entry.path enchiladaDevicePaths) sourceMetadata)
  );

  selectedLineageCategories = [
    "Default"
    { DeviceSpecific = config.device; }
  ];

  correctedArchiveHashes = {
    "external/curl" = "sha256-UbnP/jsJG3vOq1F9sf3fnti3DE/O4VP4pzSVuqS6J+c=";
    "external/libffi" = "sha256-/UTKq1fagDJb2zZbEzuBJiW1R0N4QA8ej8/10Xaa/x8=";
    "external/tpm2-tss" = "sha256-ytJBjlTHshTc6mdlgz7LgEsYaDuunT/XUB4snCqM0UE=";
    "external/webp" = "sha256-6tTcsW4BB1vqv5AU/J+hYRr8KVaVnTtH1xhLNq1VUdQ=";
  };

  shouldUseLineageArchive =
    entry:
    builtins.any (category: builtins.elem category entry.project.categories) selectedLineageCategories
    && hasPrefix "https://android.googlesource.com/" entry.project.repo_ref.repo_url;

  lineageArchiveOverrides = mapAttrs' (
    _: entry:
    nameValuePair entry.project.path {
      src = pkgs.fetchzip {
        url = "${entry.project.repo_ref.repo_url}/+archive/${entry.lock.commit}.tar.gz";
        sha256 =
          if builtins.hasAttr entry.project.path correctedArchiveHashes then
            correctedArchiveHashes.${entry.project.path}
          else
            entry.lock.nix_hash;
        stripRoot = false;
      };
    }
  ) (filterAttrs (_: entry: shouldUseLineageArchive entry) lineageLockEntries);
in
mkIf (config.flavor == "derpfest") {
  assertions = [
    {
      assertion = builtins.hasAttr config.flavorVersion derpfestBranchToAndroidVersion;
      message = "Unknown DerpFest branch `${config.flavorVersion}`. Supported branches: ${lib.concatStringsSep ", " (builtins.attrNames derpfestBranchToAndroidVersion)}";
    }
    {
      assertion = builtins.elem config.device supportedDevices;
      message = "Device `${config.device}` is not known to robotnix's LineageOS device metadata, so DerpFest cannot inherit a device tree for it.";
    }
  ];

  flavorVersion = mkDefault "16";
  androidVersion = derpfestBranchToAndroidVersion.${config.flavorVersion};
  productNamePrefix = "lineage_";
  variant = mkDefault "userdebug";
  release = mkDefault "bp2a";

  source.manifest = {
    enable = true;
    lockfile = ../lineageos/lineage-23.0/repo.lock;
    categories = [
      "Default"
      { DeviceSpecific = config.device; }
    ];
  };

  source.dirs = lineageArchiveOverrides // derpfestSources // enchiladaSources;

  apps.seedvault.includedInFlavor = mkDefault true;
  apps.updater.enable = mkDefault false;
  apps.updater.includedInFlavor = mkDefault false;

  envPackages =
    [ pkgs.openssl.dev ]
    ++ optionals (config.androidVersion >= 11) [
      pkgs.gcc.cc
      pkgs.glibc.dev
    ];

  envVars.RELEASE_TYPE = mkDefault "EXPERIMENTAL";
  signing.apex.enable = config.androidVersion >= 14;
  envVars.OVERRIDE_TARGET_FLATTEN_APEX = lib.boolToString false;

  warnings = lib.optionals (config.device == "enchilada") [
    "DerpFest for enchilada is wired as a best-effort hybrid: DerpFest Android 16 platform overrides are combined with LineageOS/TheMuppets device sources because upstream Android 16 enchilada support is incomplete."
  ];
}
