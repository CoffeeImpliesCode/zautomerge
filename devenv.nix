{ pkgs, ... }:

let
  # Use a valid sibling checkout without copying it into the Nix store.
  # An empty value leaves discovery to tools/link-oracle.sh.
  repoRoot = builtins.getEnv "PWD";
  siblingRef = repoRoot + "/../github-automerge-automerge";
  automergeRef = if repoRoot != "" && builtins.pathExists siblingRef
    then siblingRef
    else "";
in
{
  packages = with pkgs; [
    # C ABI conformance uses these; cmocka is not a port library dependency.
    cmocka
    pkg-config
    git
    jq
    # Byte-level inspection of automerge documents and sync payloads.
    xxd
  ];

  env = {
    # Upstream reference checkout. Read-only; never build or modify it.
    AUTOMERGE_REF = automergeRef;
  };

}
