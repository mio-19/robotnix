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
    recursiveUpdate
    removePrefix
    unique
    hasPrefix
    ;

  androidVersionToLineageBranch = {
    "13" = "20.0";
    "14" = "21.0";
    "15" = "22.2";
    "16" = "23.0";
  };

  parsedFlavorVersion = builtins.match "([0-9]+)(\\..*)?" config.flavorVersion;
  selectedAndroidVersion =
    if parsedFlavorVersion == null then null else builtins.fromJSON (builtins.elemAt parsedFlavorVersion 0);
  selectedLineageBranch =
    if selectedAndroidVersion == null then null else androidVersionToLineageBranch.${toString selectedAndroidVersion} or null;
  selectedLineageLockfile =
    if selectedLineageBranch == null then null else ../lineageos + "/lineage-${selectedLineageBranch}/repo.lock";

  deviceMetadata = lib.importJSON ../lineageos/devices.json;
  supportedDevices = attrNames deviceMetadata;
  sourceMetadata = lib.importJSON ./sources.generated.json;
  lineageLockEntries = (lib.importJSON selectedLineageLockfile).entries;

  isSelectedDeviceCategory =
    category: builtins.isAttrs category && (category ? DeviceSpecific) && (category.DeviceSpecific == config.device);
  isAnyDeviceCategory = category: builtins.isAttrs category && (category ? DeviceSpecific);

  lineageDeviceSpecificRoots = attrNames (
    filterAttrs
      (
        _: entry:
        builtins.any isSelectedDeviceCategory entry.project.categories
      )
      lineageLockEntries
  );
  lineageAllDeviceSpecificRoots = attrNames (
    filterAttrs
      (
        _: entry:
        builtins.any isAnyDeviceCategory entry.project.categories
      )
      lineageLockEntries
  );

  lineagePathDeps =
    path:
    if !(builtins.hasAttr path lineageLockEntries) then
      [ ]
    else
      let
        deps = lineageLockEntries.${path}.project.lineage_deps;
      in
      if builtins.isAttrs deps && (deps ? Some) then deps.Some else [ ];

  collectLineageDeps =
    pending: visited:
    if pending == [ ] then
      visited
    else
      let
        path = builtins.head pending;
        rest = builtins.tail pending;
      in
      if builtins.elem path visited then
        collectLineageDeps rest visited
      else
        collectLineageDeps (rest ++ lineagePathDeps path) (visited ++ [ path ]);

  lineageDevicePathClosure = collectLineageDeps lineageDeviceSpecificRoots [ ];
  derivedVendorPaths = builtins.map (path: "vendor/${removePrefix "device/" path}") (
    filter (path: hasPrefix "device/" path) lineageDevicePathClosure
  );
  derivedAllVendorPaths = builtins.map (path: "vendor/${removePrefix "device/" path}") (
    filter (path: hasPrefix "device/" path) lineageAllDeviceSpecificRoots
  );
  derpfestDevicePaths = unique (lineageDevicePathClosure ++ derivedVendorPaths);
  derpfestAnyDevicePaths = unique (lineageAllDeviceSpecificRoots ++ derivedAllVendorPaths);

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

  derpfestCommonSources = mkSourceDirs (
    filter (entry: !(builtins.elem entry.path derpfestAnyDevicePaths)) sourceMetadata
  );

  derpfestDeviceSources = mkSourceDirs (
    filter (entry: builtins.elem entry.path derpfestDevicePaths) sourceMetadata
  );

  selectedLineageCategories = [
    "Default"
    { DeviceSpecific = config.device; }
  ];

  correctedArchiveHashes = {
    "external/angle" = "sha256-JHKqvlojvwuXbca4qcnaY+C8E+98HmStJep5LFVsTic=";
    "external/bc" = "sha256-SWBemSKu9hMKXBz0A/ZJFqD8aBTNCktooOO5eWZ5tr0=";
    "external/curl" = "sha256-UbnP/jsJG3vOq1F9sf3fnti3DE/O4VP4pzSVuqS6J+c=";
    "external/jsoncpp" = "sha256-xawnNkTV+yHV/tvfrTTLhLcnQwsRuNhCEO5FQ3gKmpA=";
    "external/kotlinpoet" = "sha256-vDFCx4JJaWKxLjQYZLO+I/treB4lEpMvlLlhODwqGeE=";
    "external/libffi" = "sha256-/UTKq1fagDJb2zZbEzuBJiW1R0N4QA8ej8/10Xaa/x8=";
    "external/libopus" = "sha256-bYnDVlHEFYmUuMwr0+96OSoll62c2Ixmk5uIr2N/a74=";
    "external/libusb" = "sha256-hF7Eas+6BOH+ZmGoirkMF+Pr54dA6eO61R+z1yXNl2E=";
    "external/lottie" = "sha256-gAP1E4SMwGcQ+QrpdZqaQiykLgFPKTLsXmgBsUwG+Kc=";
    "external/lz4" = "sha256-YItBneq+7RoYxGIXGRX70Ud8MuRLpt8pzm4ShLy3L/0=";
    "external/mesa3d" = "sha256-Mq9TOkhRgpVaTJnrCpEhBxnn4cUyyx0jlL1GV0UtzP4=";
    "external/moshi" = "sha256-uc6lEx+Krm14ePMfBzA3ciHcRgZvLhQR5pL3n9TvW6s=";
    "external/okio" = "sha256-ilvviyGNPrOnvH7jC0kZ864IhIMPiOSItzHY88+PQzw=";
    "external/pigweed" = "sha256-rKkLnknvtpMXTrB68T3R4AbZSKq/5tEuZonrkTK9de0=";
    "external/python/cpython3" = "sha256-pncCIE8ucIYg+VqBNsvMxzZnsHGA/otcM2H0jhvBQh0=";
    "external/python/dateutil" = "sha256-gTqtHEpOLnmZjxgqtyICGwfseObya4BttFmzVUsvCxI=";
    "external/pytorch" = "sha256-+hzo7srhQP/iuhUirS6q8prxD7MjwgpQ20ycjuPrNU8=";
    "external/rust/beto-rust" = "sha256-fYS1d1mSE2lbuWorAlWXSnPCXYh98Cx8O2n0Zoiqt0A=";
    "external/scapy" = "sha256-1h80bF4j+amHKqwrENt7skbd3YyWqCTov7aw1DAtkeA=";
    "external/tpm2-tss" = "sha256-ytJBjlTHshTc6mdlgz7LgEsYaDuunT/XUB4snCqM0UE=";
    "external/vulkan-validation-layers" = "sha256-02cucclsngKCHNXYcP4GvYTM8P0UOKoWJObreyzacmw=";
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
      assertion = config.flavorVersion != null;
      message = "The `flavorVersion` config option needs to be set to the DerpFest branch, e.g. `flavorVersion = \"16\"`";
    }
    {
      assertion = selectedAndroidVersion != null;
      message = "Unable to derive androidVersion from DerpFest branch `${config.flavorVersion}`. Expected branch format like `16` or `16.2`.";
    }
    {
      assertion = selectedLineageBranch != null;
      message = "No LineageOS compatibility mapping exists for DerpFest branch `${config.flavorVersion}` (androidVersion `${toString selectedAndroidVersion}`).";
    }
    {
      assertion = builtins.elem config.device supportedDevices;
      message = "Device `${config.device}` is not known to robotnix's LineageOS device metadata, so DerpFest cannot inherit a device tree for it.";
    }
  ];

  flavorVersion = mkDefault "16";
  androidVersion = selectedAndroidVersion;
  productNamePrefix = "lineage_";
  variant = mkDefault "userdebug";
  release = mkDefault "bp2a";

  source.manifest = {
    enable = true;
    lockfile = selectedLineageLockfile;
    categories = [
      "Default"
      { DeviceSpecific = config.device; }
    ];
  };

  source.dirs = recursiveUpdate
    (lineageArchiveOverrides // derpfestCommonSources // derpfestDeviceSources)
    {
      "build/make".postPatch = ''
        # Some branches try to delete prebuilts from immutable source trees.
        sed -i 's#rm -f "\$file"#rm -f "\$file" || true#g' envsetup.sh
      '';
      "vendor/google/gms".postPatch = ''
        if [ -f vendorsetup.sh ]; then
          # GMS blobs are split into .part files upstream; merge during source patching
          # because source trees are immutable at build time.
          sed -i 's#vendor/google/gms/##g' vendorsetup.sh
          bash vendorsetup.sh
          cat > vendorsetup.sh <<'EOF'
#!/usr/bin/env bash
# Blobs were pre-merged during source patching.
true
EOF
          chmod +x vendorsetup.sh
        fi
      '';
      "vendor/lineage".postPatch = ''
        # Avoid broken-pipe exits under `set -o pipefail` in non-interactive builds.
        sed -i "s#ALPHA=\$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)#ALPHA=\$(od -An -N2 -tx1 /dev/urandom | tr -d ' \\\\n')#g" build/envsetup.sh

        if [ ! -f config/device_framework_matrix.xml ]; then
          cat > config/device_framework_matrix.xml <<'EOF'
<?xml version="2.0" encoding="UTF-8"?>
<!--
     Copyright (C) 2021-2025 The LineageOS Project
     SPDX-License-Identifier: Apache-2.0
-->
<compatibility-matrix version="2.0" type="framework">
    <!-- Radio Config (backend) -->
    <hal format="hidl" optional="true">
        <name>lineage.hardware.radio.config</name>
        <version>1.0-1</version>
        <interface>
            <name>IRadioConfig</name>
            <instance>default</instance>
        </interface>
    </hal>
    <!-- Charging -->
    <hal format="aidl" optional="true">
        <name>vendor.lineage.health</name>
        <version>1-2</version>
        <interface>
            <name>IChargingControl</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IFastCharge</name>
            <instance>default</instance>
        </interface>
    </hal>
    <hal format="aidl" optional="true">
        <name>vendor.lineage.powershare</name>
        <version>1</version>
        <interface>
            <name>IPowerShare</name>
            <instance>default</instance>
        </interface>
    </hal>
    <!-- Display -->
    <hal format="aidl" optional="true">
        <name>vendor.lineage.livedisplay</name>
        <version>1</version>
        <interface>
            <name>IAdaptiveBacklight</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IAntiFlicker</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IAutoContrast</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IColorBalance</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IColorEnhancement</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IDisplayColorCalibration</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IDisplayModes</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IPictureAdjustment</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IReadingEnhancement</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>ISunlightEnhancement</name>
            <instance>default</instance>
        </interface>
    </hal>
    <!-- Touch -->
    <hal format="aidl" optional="true">
        <name>vendor.lineage.touch</name>
        <version>1</version>
        <interface>
            <name>IGloveMode</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IHighTouchPollingRate</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IKeyDisabler</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IKeySwapper</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>IStylusMode</name>
            <instance>default</instance>
        </interface>
        <interface>
            <name>ITouchscreenGesture</name>
            <instance>default</instance>
        </interface>
    </hal>
</compatibility-matrix>
EOF
        fi
      '';
      "vendor/oneplus/enchilada".postPatch = ''
        if [ -f Android.mk ]; then
          sed -i 's/add-radio-file-sha1-checked/add-radio-file/g' Android.mk
        fi
      '';
      "packages/overlays/Lineage".enable = false;
      "vendor/apn".enable = false;
    };

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

  warnings = lib.optionals (lineageDeviceSpecificRoots == [ ]) [
    "No device-specific sources were found for `${config.device}` in LineageOS branch `${selectedLineageBranch}`; this DerpFest build is unlikely to succeed."
  ];
}
