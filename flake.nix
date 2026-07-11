{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
    }:
    let
      mapSupportedSystems = nixpkgs.lib.genAttrs (import systems);
      forEachSupportedSystem = f: mapSupportedSystems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Xcode本体とSwiftツールチェーンはNix管理外（システムのXcodeを使う）。
      # mkShellNoCC: NixのclangラッパーがxcodebuildやSwiftPMの
      # ツールチェーン解決を壊さないようにするため。
      devShells = forEachSupportedSystem (pkgs: {
        default = pkgs.mkShellNoCC {
          buildInputs = with pkgs; [
            swiftlint
            swiftformat
            xcodegen
            xcbeautify
            tmux
          ];
        };
      });
    };
}
