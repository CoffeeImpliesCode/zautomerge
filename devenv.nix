{ pkgs, ... }:

let
  # The read-only reference checkout of the upstream Rust implementation that
  # `zautomerge` is a direct translation of. Tests and tools read fixtures from
  # it, so the path is exported rather than copied.
  automergeRef = "~/projects/github-automerge-automerge";
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
    ZLS_EXE = "~/.local/bin/zls";
  };

  scripts.gate.exec = "zig-gate";
}
