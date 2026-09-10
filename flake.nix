{
  description = "Zig and ZLS development environment for NixOS 26.05";

  inputs = {
    # Pinning exactly to the NixOS 26.05 stable release branch
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          # Packages loaded directly into the shell environment's $PATH
          buildInputs = with pkgs; [
            zig
            zls
          ];

          # Optional shell hook to confirm it loaded correctly
          shellHook = ''
            echo "⚡ Zig $(zig version) & ZLS dev environment loaded (NixOS 26.05)"
          '';
        };
      });
}

