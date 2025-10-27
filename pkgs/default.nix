# SPDX-FileCopyrightText: 2020 Daniel Fullmer and robotnix contributors
# SPDX-License-Identifier: MIT

{ 
  system ? builtins.currentSystem,
  inputs ? (import ../flake/compat.nix { inherit system; }).defaultNix.inputs,
  ...
}@args:

let
  inherit (inputs) nixpkgs androidPkgs;
in nixpkgs.legacyPackages.aarch64-darwin.appendOverlays [
  (self: super: {
    androidPkgs.packages = androidPkgs.packages.aarch64-darwin;
    androidPkgs.sdk = androidPkgs.sdk.aarch64-darwin;
  })
  (import ./overlay.nix { inherit inputs; })
]
