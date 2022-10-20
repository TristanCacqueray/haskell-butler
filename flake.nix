{
  nixConfig.bash-prompt = "[nix(butler)] ";
  inputs = {
    hspkgs.url =
      "github:podenv/hspkgs/acb9b59f2dc1cfb11ffe1b1062449c8a5dc2f145";
    # "path:///srv/github.com/podenv/hspkgs";
  };
  outputs = { self, hspkgs }:
    let
      pkgs = hspkgs.pkgs;
      haskellExtend = hpFinal: hpPrev: {
        butler = hpPrev.callCabal2nix "butler" self { };
      };
      hsPkgs = pkgs.hspkgs.extend haskellExtend;

      desktop = with pkgs; [
        nixGLIntel
        # xvfb-run
        xdummy
        # tigervnc
        x11vnc
        xorg.xrandr
        glxinfo
        openbox
        xterm
        autocutsel
      ];

      # manually adds build dependencies that are not managed by cabal2nix
      addExtraDeps = drv:
        pkgs.haskell.lib.addBuildDepends drv ([ hsPkgs.tasty-discover ]);

    in {
      packages."x86_64-linux".default =
        pkgs.haskell.lib.justStaticExecutables hsPkgs.butler;
      devShell."x86_64-linux" = hsPkgs.shellFor {
        packages = p: [ (addExtraDeps p.butler) ];
        buildInputs = with pkgs;
          [
            hpack
            cabal-install
            ghcid
            haskell-language-server
            fourmolu
            hsPkgs.doctest
            hsPkgs.tasty-discover
          ] ++ desktop;
      };
    };
}
