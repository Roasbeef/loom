#!/usr/bin/env bash
# Run a package with named EUnit progress and an independent process deadline.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
package="${1:?usage: scripts/test.sh package [--match module-or-function]}"
shift
known="host core storage session machine prompt telemetry runtime provider broker mcp tools cap ext codemode events client conformance tui lint"
case " $known " in
  *" $package "*) ;;
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

# LOOM_TEST_PARALLEL asks EUnit to run tests concurrently, up to this many at
# a time, on the one emulator the runner already starts. Unset, empty, or 1
# leaves the run exactly as it was: the same sequential order and the same
# output. Anything else must be a positive integer, because a typo that
# silently fell back to sequential would make a timing measurement claim a
# speedup it never had.
#
# The concurrency is not per module. EUnit propagates an inparallel group's
# ordering down the whole subtree beneath it, so wrapping the module list
# makes every individual test in the package eligible to run beside every
# other one, including two tests inside the same module. A suite whose tests
# share a fixture between themselves is therefore just as exposed as two
# suites that share one.
#
# The variable is opt-in rather than a default because EUnit gives concurrent
# test representations no isolation whatsoever. They share one node, so they
# share every registered process name, every listening port, every scratch
# path derived from a clock reading, every environment variable, and the
# package's single started application. A module is safe to run beside its
# siblings only if everything it touches outside its own process is named
# uniquely per run; anything reaching the outside world under a shared name
# will collide, and the collision usually reads as an unrelated failure.
parallel="${LOOM_TEST_PARALLEL:-1}"
if ! [[ "$parallel" =~ ^[1-9][0-9]*$ ]]; then
  echo "LOOM_TEST_PARALLEL must be a positive integer, got: $parallel" >&2
  exit 2
fi

# Some modules cannot share the emulator with anything, because what they
# assert about is global to the node rather than to the test. Those are
# declared in scripts/serial-tests with the resource named, and the runner
# reads the declaration here rather than carrying a list in its own source:
# the file is what a reviewer reads when asking why a module is exempt.
#
# The whole file is validated on every run, not just this package's lines,
# so a malformed entry is found by the first package that runs rather than
# by the one it belongs to. Whether the declared modules actually exist is
# checked in the emulator below, where the discovered module list lives.
serial_file="$root/scripts/serial-tests"
serial=""
if [ "$parallel" -gt 1 ] && [ -z "$match" ]; then
  serial="$(awk -F'|' -v want="$package" -v known=" $known " '
    /^[[:space:]]*(#|$)/ { next }
    NF != 3 || $1 == "" || $2 == "" || $3 == "" {
      printf "scripts/serial-tests:%d: expected <package>|<module>|<reason>\n", NR > "/dev/stderr"
      bad = 1
      next
    }
    index(known, " " $1 " ") == 0 {
      printf "scripts/serial-tests:%d: unknown package %s\n", NR, $1 > "/dev/stderr"
      bad = 1
      next
    }
    $1 == want { print $2 }
    END { if (bad) exit 2 }
  ' "$serial_file")" || exit 2
fi

export LOOM_TEST_PACKAGE="$package" LOOM_TEST_MATCH="$match"
export LOOM_TEST_PARALLEL="$parallel"
export LOOM_TEST_SERIAL="$serial"
cd "$root/packages/$package"
# The runner's own body is wrapped for two reasons. A raise inside it — the
# --match path's `{module, M} = code:ensure_loaded(M)` is the reachable one —
# otherwise reports as an emulator boot crash, writes an erl_crash.dump into
# the package directory and exits 1, which is the status an ordinary test
# failure already uses; status 3 and a named stacktrace tell the two apart.
# And every exit goes through Halt, whose synchronous empty write orders the
# whole eunit report ahead of the emulator's own shutdown.
python3 "$root/scripts/with_timeout.py" "${LOOM_TEST_TIMEOUT_SECONDS:-1200}" -- \
  bash -c 'gleam build --warnings-as-errors && exec erl -pa build/dev/erlang/*/ebin -noshell -eval "
    Halt = fun(Code) ->
      io:format(standard_io, \"\", []),
      erlang:halt(Code, [{flush, true}])
    end,
    try
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

      %% A parallel run splits the module list into two groups. EUnit pushes
      %% the inparallel ordering down into every nested item, so the
      %% limit counts individual tests rather than modules and no module is
      %% internally sequential; that is what makes the split necessary, since
      %% a module cannot opt itself out from inside. Only the unfiltered path
      %% is grouped: --match already names individual tests, and reordering
      %% those would change what a focused debugging run means.
      %%
      %% The declared modules must not merely be internally sequential, they
      %% must not overlap the parallel group at all. Each of them reads a
      %% resource global to the emulator — the atom counter, the
      %% persistent_term slot holding the capability channel — so any
      %% concurrent test that allocates an atom or installs a channel
      %% changes the answer, whether or not the two share a group. The enclosing {inorder, ...}
      %% is what enforces that: EUnit runs its members in order and waits for
      %% each, so the parallel group finishes before the serial one begins,
      %% and the serial ones then run one at a time.
      %%
      %% A declared module that no longer exists fails the run. Each
      %% declaration carries a written reason naming a resource, and a
      %% reason attached to a module that has been renamed or deleted is a
      %% claim nobody can check.
      Parallel = list_to_integer(os:getenv(\"LOOM_TEST_PARALLEL\", \"1\")),
      Serial = [list_to_atom(S) || S <- string:lexemes(os:getenv(\"LOOM_TEST_SERIAL\", \"\"), \" \n\")],
      case Serial -- Modules of
        [] -> ok;
        Stale ->
          io:format(standard_error,
            \"scripts/serial-tests declares modules absent from ~s: ~p~n\",
            [os:getenv(\"LOOM_TEST_PACKAGE\"), Stale]),
          Halt(2)
      end,
      Grouped = case {Pattern, Parallel} of
        {\"\", N} when N > 1 ->
          [{inorder, [{inparallel, N, Tests -- Serial}, {inorder, Serial}]}];
        _ -> Tests
      end,
      case Tests of
        [] -> io:format(standard_error, \"No tests matched ~tp~n\", [Pattern]), Halt(2);
        _ -> case eunit:test(Grouped, [verbose, {scale_timeouts, 10}]) of
          ok -> Halt(0);
          error -> Halt(1)
        end
      end
    catch Class:Reason:Stack ->
      io:format(standard_error, \"test runner failed: ~p:~p~n~p~n\", [Class, Reason, Stack]),
      erlang:halt(3, [{flush, true}])
    end."
  '
