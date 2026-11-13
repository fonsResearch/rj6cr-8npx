# Put the project toolchain on PATH. Usage: source tools/env.sh
#
# - OCaml / Hardcaml: opam switch "hardcaml" in ~/.opam
# - Yosys, sby, iverilog and the PDK: expected under .toolchain/ at the repository root
#   (eda/bin and pdk/). .toolchain may be a symbolic link and is not tracked.
#   Versions are listed in log/ground_truth.md.

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

if command -v opam >/dev/null 2>&1; then
  eval "$(opam env --switch=hardcaml --set-switch)"
elif [ -d "$HOME/.opam/hardcaml/bin" ]; then
  export OPAM_SWITCH_PREFIX="$HOME/.opam/hardcaml"
  export PATH="$OPAM_SWITCH_PREFIX/bin:$PATH"
  export CAML_LD_LIBRARY_PATH="$OPAM_SWITCH_PREFIX/lib/stublibs:$OPAM_SWITCH_PREFIX/lib/ocaml/stublibs"
fi

export PATH="$_repo_root/.toolchain/eda/bin:$PATH"
export PDK_ROOT="${PDK_ROOT:-$_repo_root/.toolchain/pdk}"
unset _repo_root
