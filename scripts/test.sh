#!/usr/bin/env bash
# Run a package with named EUnit progress and an independent process deadline.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
package="${1:?usage: scripts/test.sh package [--match module-or-function]}"
shift
case "$package" in
  core|storage|session|machine|prompt|telemetry|runtime|provider|broker|mcp|tools|cap|ext|codemode|events|client|conformance|tui|lint) ;;
  *) echo "unknown test package: $package" >&2; exit 2 ;;
esac
match=""
if [ "$#" -ne 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--match" ] || [ -z "$2" ]; then
    echo "usage: scripts/test.sh package [--match module-or-function]" >&2
    exit 2
  fi
  match="$2"
fi
export LOOM_TEST_PACKAGE="$package" LOOM_TEST_MATCH="$match"
cd "$root/packages/$package"
python3 "$root/scripts/with_timeout.py" "${LOOM_TEST_TIMEOUT_SECONDS:-1200}" -- \
  bash -c 'gleam build --warnings-as-errors && exec erl -pa build/dev/erlang/*/ebin -noshell -eval "
    {ok, _} = application:ensure_all_started(list_to_atom(os:getenv(\"LOOM_TEST_PACKAGE\"))),
    Files = filelib:wildcard(\"test/**/*.{gleam,erl}\"),
    Modules = lists:usort([list_to_atom(lists:flatten(case filename:extension(F) of
      \".erl\" -> filename:basename(F, \".erl\");
      \".gleam\" -> string:replace(filename:rootname(string:prefix(F, \"test/\")), \"/\", \"@\", all)
    end)) || F <- Files]),
    Pattern = os:getenv(\"LOOM_TEST_MATCH\"),
    Tests = case Pattern of
      \"\" -> Modules;
      _ -> lists:flatmap(fun(M) ->
        {module, M} = code:ensure_loaded(M),
        lists:filtermap(fun({F, Arity}) ->
          Name = atom_to_list(F),
          Matched = string:find(atom_to_list(M) ++ \":\" ++ Name, Pattern) =/= nomatch,
          case {Arity, Matched, lists:suffix(\"_test\", Name), lists:suffix(\"_test_\", Name)} of
            {0, true, true, _} -> {true, {M, F}};
            {0, true, _, true} -> {true, {generator, M, F}};
            _ -> false
          end
        end, M:module_info(exports))
      end, Modules)
    end,
    case Tests of
      [] -> io:format(standard_error, \"No tests matched ~tp~n\", [Pattern]), halt(2);
      _ -> case eunit:test(Tests, [verbose, {scale_timeouts, 10}]) of
        ok -> halt(0);
        error -> halt(1)
      end
    end."
  '
