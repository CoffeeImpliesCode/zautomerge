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
    git
    jq
    # Byte-level inspection of automerge documents and sync payloads.
    xxd
  ];

  env = {
    # Upstream reference checkout. Read-only; never build or modify it.
    AUTOMERGE_REF = automergeRef;
    ZLS_EXE = builtins.getEnv "HOME" + "/.local/bin/zls";
  };

  # `gate` is the house gate, and its cross-compilation section reads
  # `test/cross-test.profile.sh` — cross-test discovers `./cross-test.profile.sh`
  # first and `./test/cross-test.profile.sh` second, and zig-gate fails outright
  # when neither exists. That file is where the portability matrix, the
  # one-target-one-job concurrency and the deadlines live, and it lives there
  # rather than here because cross-test owns the paths a run writes to (output
  # prefix, cache, TMPDIR): a committed path is valid only on the machine that
  # wrote it. The caller supplies the compiler and the private cache; this file
  # pins neither.
  scripts.gate.exec = "zig-gate";
}
