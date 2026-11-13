//// The decisions behind `loom vm up --link untrusted`, held still: the flag,
//// the guest's link and port records, the merge of `[executor_link]` and a
//// guest's row into a `loom.toml`, the executor's own configuration, the
//// credentials `up` mints, and the mask that keeps a listener's key from a
//// jail. Nothing here boots a guest; `daemon_shipped_microvm_test` does that.
////
//// The merge is checked against the daemon's own readers: what `install`
//// writes is parsed by `executors.parse` and `untrusted_config.parse`, and the
//// credentials `vm_link_pki` mints are used for a real handshake that pins the
//// leaf the way the link does. Properties draw from a fixed seed.

import client/distribution
import client/executors
import client/internal/ffi_pki
import client/internal/ffi_tls_stream
import client/untrusted_config
import client/vm_link.{type LinkFiles, type Row, LinkFiles, Row}
import client/vm_link_pki
import client/vm_spec
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import simplifile
import support/remote_fixtures as fixtures
import support/untrusted_rig as rig
import tom

const seed = 20_261_113

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(300)
  |> qcheck.with_seed(qcheck.seed(seed))
}

// --- the flag ----------------------------------------------------------------

pub fn the_link_flag_reads_both_words_and_refuses_others_test() {
  let assert Ok(vm_spec.Up(options)) =
    vm_spec.parse(["up", "--link", "untrusted"])
  assert options.link == Some(vm_spec.Untrusted)

  let assert Ok(vm_spec.Up(options)) =
    vm_spec.parse(["up", "--link", "distribution"])
  assert options.link == Some(vm_spec.Distribution)

  let assert Ok(vm_spec.Up(options)) = vm_spec.parse(["up"])
  assert options.link == None

  let assert Error(reason) = vm_spec.parse(["up", "--link", "tls"])
  assert string.contains(reason, "distribution or untrusted")
}

pub fn ensure_takes_the_link_flag_too_test() {
  let assert Ok(vm_spec.Ensure(options)) =
    vm_spec.parse(["ensure", "--link", "untrusted", "--github", "off"])
  assert options.link == Some(vm_spec.Untrusted)
  assert options.github == Some(vm_spec.GitHubOff)
}

pub fn a_guest_cannot_be_named_for_the_vm_homes_link_directory_test() {
  assert result.is_error(vm_spec.valid_name(vm_spec.link_dir))
}

// --- the records ---------------------------------------------------------------

pub fn a_link_record_round_trips_and_a_missing_one_is_distribution_test() {
  list.each([vm_spec.Distribution, vm_spec.Untrusted], fn(kind) {
    assert vm_link.decode_kind(Some(vm_link.encode_kind(kind))) == Ok(kind)
  })
  assert vm_link.decode_kind(None) == Ok(vm_spec.Distribution)
}

pub fn decoding_a_link_record_is_total_and_names_only_the_two_kinds_test() {
  qcheck.run(config(), qcheck.string(), fn(text) {
    // Whatever the text, the answer is a kind named by the text or an error;
    // it is never a default that could turn an untrusted guest trusted.
    case vm_link.decode_kind(Some(text)) {
      Ok(kind) -> {
        assert string.trim(text) == vm_link.kind_word(kind)
      }
      Error(_) -> Nil
    }
  })
}

pub fn a_port_record_round_trips_and_only_canonical_ports_decode_test() {
  qcheck.run(config(), qcheck.bounded_int(1, 65_535), fn(port) {
    assert vm_link.decode_port(vm_link.encode_port(port)) == Ok(port)
  })

  list.each(["0", "65536", "-1", "+80", "080", "", "80x", "8 0"], fn(text) {
    assert result.is_error(vm_link.decode_port(text))
  })
}

pub fn decoding_a_port_record_is_total_test() {
  qcheck.run(config(), qcheck.string(), fn(text) {
    case vm_link.decode_port(text) {
      Ok(port) -> {
        assert port >= 1 && port <= 65_535
      }
      Error(_) -> Nil
    }
  })
}

pub fn a_free_recorded_port_is_kept_and_any_other_is_replaced_test() {
  assert vm_link.port_step(vm_link.Recorded(41_000, vm_link.Free))
    == vm_link.Keep(41_000)
  assert vm_link.port_step(vm_link.Recorded(41_000, vm_link.InUse))
    == vm_link.Reserve
  assert vm_link.port_step(vm_link.NotRecorded) == vm_link.Reserve
}

// --- which link a guest has -------------------------------------------------------

pub fn a_new_guest_takes_the_flag_and_defaults_to_distribution_test() {
  assert vm_link.settle("dev", None, vm_link.NoBundles, Some(vm_spec.Untrusted))
    == Ok(vm_spec.Untrusted)
  assert vm_link.settle("dev", None, vm_link.NoBundles, None)
    == Ok(vm_spec.Distribution)
}

pub fn an_existing_guest_keeps_its_link_when_no_flag_is_given_test() {
  assert vm_link.settle("dev", Some("untrusted\n"), vm_link.NoBundles, None)
    == Ok(vm_spec.Untrusted)

  // Bundles with no record are a guest made before the record existed.
  assert vm_link.settle("dev", None, vm_link.HasBundles, None)
    == Ok(vm_spec.Distribution)
}

pub fn a_guest_asked_to_change_its_link_is_refused_naming_fresh_and_rm_test() {
  let assert Error(reason) =
    vm_link.settle(
      "dev",
      Some("untrusted\n"),
      vm_link.NoBundles,
      Some(vm_spec.Distribution),
    )
  assert string.contains(reason, "--fresh")
  assert string.contains(reason, "loom vm rm --name dev --yes")

  assert result.is_error(vm_link.settle(
    "dev",
    None,
    vm_link.HasBundles,
    Some(vm_spec.Untrusted),
  ))
}

pub fn a_record_that_cannot_be_read_refuses_instead_of_defaulting_test() {
  assert result.is_error(vm_link.settle(
    "dev",
    Some("tls\n"),
    vm_link.NoBundles,
    None,
  ))
}

pub fn the_link_a_guest_settles_on_never_disagrees_with_what_it_has_test() {
  let records = [None, Some("distribution\n"), Some("untrusted\n")]
  let bundles = [vm_link.HasBundles, vm_link.NoBundles]
  let asks = [None, Some(vm_spec.Distribution), Some(vm_spec.Untrusted)]

  // Every combination: a settled kind is what the guest was made with, or the
  // flag for a guest that was made with nothing.
  list.each(records, fn(record) {
    list.each(bundles, fn(bundle) {
      list.each(asks, fn(asked) {
        case vm_link.settle("dev", record, bundle, asked) {
          Ok(kind) -> {
            assert asked == None || asked == Some(kind)
            case record {
              Some(text) -> {
                assert vm_link.decode_kind(Some(text)) == Ok(kind)
              }
              None -> Nil
            }
          }
          Error(_) -> Nil
        }
      })
    })
  })
}

// --- the pin ---------------------------------------------------------------------

pub fn the_pin_is_what_the_link_checks_a_leaf_against_test() {
  let #(ca, ca_key) = ffi_pki.authority("pin test authority")
  let assert Ok(#(certificate, _key)) =
    ffi_pki.issue(ca, ca_key, "leaf", ["localhost"])
  let assert Ok(text) = vm_link.pin_of(certificate)
  let assert Ok(bytes) = ffi_pki.pin(certificate)

  assert string.length(text) == 64
  assert untrusted_config.pin_of(text, "executors.dev.pin") == Ok(bytes)
  assert result.is_error(vm_link.pin_of("not a certificate"))
}

// --- the host's configuration ---------------------------------------------------------

const pin_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const pin_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

fn files() -> LinkFiles {
  LinkFiles(
    ca: "/vm/link/ca.pem",
    certificate: "/vm/link/orchestrator.pem",
    key: "/vm/link/orchestrator.key",
  )
}

fn row_on(port: Int) -> Row {
  Row(name: "dev", port:, pin: pin_a)
}

// The fragments a user's own `loom.toml` may hold, which `install` must leave
// exactly as they are. The first is a ledger deployment, the second a static
// one's trusted row, and the last an untrusted row someone wrote by hand.
fn fragments() -> List(String) {
  [
    "[distribution]\nnode = \"owner@10.0.0.1\"\nca = \"/etc/loom/ca.pem\"\n"
      <> "certificate = \"/etc/loom/cert.pem\"\nkey = \"/etc/loom/key.pem\"\n"
      <> "cookie = \"/home/loom/.erlang.cookie\"\n"
      <> "ledger = \"/var/loom/ledger.log\"\n",
    "# the owner's own notes\n",
    "[tools]\nnetwork = \"full\"\n",
    "[workspaces.proj]\nroot = \"/srv/proj\"\n",
    "[executors.trusted-a]\nnode = \"peer@127.0.0.1\"\n",
    "[executors.other]\ntrust = \"untrusted\"\naddress = \"127.0.0.1:9000\"\n"
      <> "pin = \""
      <> pin_b
      <> "\"\n",
  ]
}

// A configuration drawn as a subset of the fragments, in order.
fn bases() -> qcheck.Generator(String) {
  qcheck.fixed_length_list_from(qcheck.bounded_int(0, 1), 6)
  |> qcheck.map(fn(chosen) {
    list.zip(chosen, fragments())
    |> list.filter(fn(entry) { entry.0 == 1 })
    |> list.map(fn(entry) { entry.1 })
    |> string.join("\n")
  })
}

fn merged(text: String, row: Row) -> vm_link.Merged {
  let assert Ok(merged) = vm_link.install(text, files(), row, "loom.toml")
    as "the merge is accepted"
  merged
}

fn document(text: String) -> dict.Dict(String, tom.Toml) {
  let assert Ok(parsed) = tom.parse(text) as "the text is TOML"
  parsed
}

// The document without the two tables a guest owns, so two texts can be
// compared on everything else.
fn without_guest(text: String, name: String) -> dict.Dict(String, tom.Toml) {
  let parsed = dict.delete(document(text), "executor_link")
  case dict.get(parsed, "executors") {
    Ok(tom.Table(rows)) ->
      case dict.delete(rows, name) |> dict.is_empty {
        True -> dict.delete(parsed, "executors")
        False ->
          dict.insert(parsed, "executors", tom.Table(dict.delete(rows, name)))
      }
    _ -> parsed
  }
}

pub fn an_empty_file_gains_both_tables_test() {
  let outcome = merged("", row_on(41_000))
  assert outcome.change == vm_link.Added
  assert string.contains(
    outcome.text,
    "[executor_link]\nca = \"/vm/link/ca.pem\"",
  )
  assert string.contains(
    outcome.text,
    "[executors.dev]\ntrust = \"untrusted\"\naddress = \"127.0.0.1:41000\"",
  )
}

pub fn the_daemons_own_readers_accept_what_install_writes_test() {
  let outcome = merged("", row_on(41_000))

  let assert Ok([executor]) = executors.parse(outcome.text)
  assert executor.name == "dev"
  assert executor.node == ""
  let assert executors.Untrusted(host:, port:, pin:) = executor.trust
  assert host == "127.0.0.1"
  assert port == 41_000
  assert untrusted_config.pin_of(pin_a, "pin") == Ok(pin)

  let assert Ok(settings) = untrusted_config.parse(outcome.text)
  assert settings.listener == None
  assert settings.link
    == Some(ffi_tls_stream.Credentials(
      ca: "/vm/link/ca.pem",
      certificate: "/vm/link/orchestrator.pem",
      key: "/vm/link/orchestrator.key",
    ))
}

pub fn a_ledger_deployment_takes_the_rows_as_they_are_test() {
  let assert [ledger, ..] = fragments()
  let outcome = merged(ledger, row_on(41_000))

  // The deployment table is untouched, the daemon's own readers accept the
  // file, and the ledger's row reader passes the written row through.
  assert string.starts_with(outcome.text, ledger)
  assert outcome.change == vm_link.Added
  assert result.is_ok(executors.parse(outcome.text))
  assert result.is_ok(untrusted_config.parse(outcome.text))
  let assert Ok(Some(_)) = distribution.parse(outcome.text)
}

pub fn install_is_idempotent_test() {
  qcheck.run(
    config(),
    qcheck.tuple2(bases(), qcheck.bounded_int(1, 65_535)),
    fn(drawn) {
      let #(base, port) = drawn
      let first = merged(base, row_on(port))
      let again = merged(first.text, row_on(port))
      assert again.text == first.text
      assert again.change == vm_link.Unchanged
    },
  )
}

pub fn install_changes_nothing_but_the_guests_two_tables_test() {
  qcheck.run(
    config(),
    qcheck.tuple2(bases(), qcheck.bounded_int(1, 65_535)),
    fn(drawn) {
      let #(base, port) = drawn
      let outcome = merged(base, row_on(port))

      // Everything the file held, in every table, is as it was.
      assert without_guest(outcome.text, "dev") == without_guest(base, "dev")
      assert string.starts_with(outcome.text, string.trim_end(base))
    },
  )
}

pub fn a_moved_port_rewrites_only_the_guests_row_test() {
  qcheck.run(
    config(),
    qcheck.tuple3(
      bases(),
      qcheck.bounded_int(1, 65_535),
      qcheck.bounded_int(1, 65_535),
    ),
    fn(drawn) {
      let #(base, first_port, second_port) = drawn
      let first = merged(base, row_on(first_port))
      let second = merged(first.text, row_on(second_port))

      // The same port is no move, and another port is one that leaves the
      // rest of the file and the link table as they were.
      case first_port == second_port {
        True -> {
          assert second.change == vm_link.Unchanged
        }
        False -> {
          assert second.change == vm_link.Moved
          assert !string.contains(
            second.text,
            "127.0.0.1:" <> int.to_string(first_port) <> "\"",
          )
          assert without_guest(second.text, "dev") == without_guest(base, "dev")
          assert dict.get(document(second.text), "executor_link")
            == dict.get(document(first.text), "executor_link")
        }
      }
    },
  )
}

pub fn a_row_of_the_same_name_that_differs_is_refused_and_nothing_is_merged_test() {
  let foreign = [
    // A trusted row of the same name.
    "[executors.dev]\nnode = \"peer@127.0.0.1\"\n",
    // An untrusted row with another pin, which is another guest's leaf.
    "[executors.dev]\ntrust = \"untrusted\"\naddress = \"127.0.0.1:9000\"\n"
      <> "pin = \""
      <> pin_b
      <> "\"\n",
    // The guest's own row with a key the user added, which a moved port would
    // lose if it were rewritten.
    "[executors.dev]\ntrust = \"untrusted\"\naddress = \"127.0.0.1:9000\"\n"
      <> "pin = \""
      <> pin_a
      <> "\"\nplatform = \"linux/arm64\"\n",
  ]

  list.each(foreign, fn(text) {
    let assert Error(reason) =
      vm_link.install(text, files(), row_on(41_000), "loom.toml")
    assert string.contains(reason, "[executors.dev]")
    assert string.contains(reason, "loom.toml")
  })
}

pub fn an_executor_link_that_names_other_files_is_refused_test() {
  let text =
    "[executor_link]\nca = \"/else/ca.pem\"\ncertificate = \"/else/c.pem\"\n"
    <> "key = \"/else/c.key\"\n"
  let assert Error(reason) =
    vm_link.install(text, files(), row_on(41_000), "loom.toml")
  assert string.contains(reason, "[executor_link]")
}

pub fn text_that_is_not_toml_is_refused_naming_the_file_test() {
  let assert Error(reason) =
    vm_link.install("[executors", files(), row_on(41_000), "/h/loom.toml")
  assert string.contains(reason, "/h/loom.toml")
}

pub fn a_row_that_is_already_there_leaves_the_file_unchanged_test() {
  let first = merged("# mine\n", row_on(41_000))
  let again = merged(first.text, row_on(41_000))
  assert again.change == vm_link.Unchanged
  assert again.text == first.text
}

// --- removal --------------------------------------------------------------------------

fn removal(text: String, remaining: vm_link.Remaining) -> vm_link.Removal {
  let assert Ok(removal) =
    vm_link.uninstall(text, "dev", remaining, files(), "loom.toml")
    as "the removal is accepted"
  removal
}

pub fn removing_the_last_guest_restores_what_the_file_held_test() {
  qcheck.run(
    config(),
    qcheck.tuple2(bases(), qcheck.bounded_int(1, 65_535)),
    fn(drawn) {
      let #(base, port) = drawn
      let installed = merged(base, row_on(port))
      let removed = removal(installed.text, vm_link.LastLinked)

      // A hand-written untrusted row keeps `[executor_link]` for itself.
      let others = string.contains(base, "[executors.other]")
      assert dict.has_key(document(removed.text), "executor_link") == others
      assert dict.get(rows_of(removed.text), "dev") == Error(Nil)
      assert without_guest(removed.text, "dev") == without_guest(base, "dev")
    },
  )
}

// The `[executors]` rows of a text, none when it has no such table.
fn rows_of(text: String) -> dict.Dict(String, tom.Toml) {
  case dict.get(document(text), "executors") {
    Ok(tom.Table(rows)) -> rows
    _ -> dict.new()
  }
}

pub fn removing_a_guest_while_others_remain_keeps_the_link_table_test() {
  let installed = merged("", row_on(41_000))
  let removed = removal(installed.text, vm_link.OthersRemain)
  assert removed.removed == [["executors", "dev"]]
  assert dict.has_key(document(removed.text), "executor_link")
}

pub fn removing_the_last_guest_removes_the_link_table_test() {
  let installed = merged("", row_on(41_000))
  let removed = removal(installed.text, vm_link.LastLinked)
  assert removed.removed == [["executors", "dev"], ["executor_link"]]
  assert !dict.has_key(document(removed.text), "executor_link")
}

pub fn a_row_that_is_not_untrusted_is_never_removed_test() {
  let text = "[executors.dev]\nnode = \"peer@127.0.0.1\"\n"
  let removed = removal(text, vm_link.LastLinked)
  assert removed.removed == []
  assert removed.text == text
}

pub fn a_link_table_that_names_other_files_is_never_removed_test() {
  let installed = merged("", row_on(41_000))
  let edited = string.replace(installed.text, "/vm/link/ca.pem", "/else/ca.pem")
  let removed = removal(edited, vm_link.LastLinked)
  assert removed.removed == [["executors", "dev"]]
  assert dict.has_key(document(removed.text), "executor_link")
}

pub fn the_last_untrusted_guest_is_known_from_the_others_links_test() {
  assert vm_link.remaining([]) == vm_link.LastLinked
  assert vm_link.remaining([vm_spec.Distribution]) == vm_link.LastLinked
  assert vm_link.remaining([vm_spec.Distribution, vm_spec.Untrusted])
    == vm_link.OthersRemain
}

// --- the guest's root --------------------------------------------------------------------

pub fn the_guest_listens_admits_one_pin_and_has_no_distribution_test() {
  let text =
    vm_link.guest_config(
      vm_spec.guest_files(),
      pin_a,
      ["proj"],
      vm_spec.GitHubOff,
      [],
    )

  let assert Ok(settings) = untrusted_config.parse(text)
  let assert Some(listener) = settings.listener
  assert listener.address == ""
  assert listener.port == vm_spec.guest_port
  assert listener.credentials.key == "/srv/loom-node/creds/key.pem"
  assert Ok(listener.orchestrators)
    == result.map(untrusted_config.pin_of(pin_a, "pin"), fn(pin) { [pin] })

  // No node name, no peers and no cookie: the daemon would refuse both tables
  // together, and an untrusted executor is never a peer.
  assert distribution.parse(text) == Ok(None)
  assert !string.contains(text, "[distribution]")
  assert !string.contains(text, "cookie")
  assert string.contains(text, "[workspaces.proj]")
}

pub fn the_staged_files_hold_one_key_and_no_cookie_test() {
  let config = "[executor_listener]\n"
  let staged =
    vm_link.staging(vm_spec.guest_files(), "CA", "CERT", "KEY", config)
  let paths = list.map(staged, fn(file) { file.path })

  assert paths
    == [
      "/srv/loom-node/creds/ca.pem",
      "/srv/loom-node/creds/cert.pem",
      "/srv/loom-node/creds/key.pem",
      "/srv/loom-node/loom.toml",
    ]
  assert !list.any(paths, string.contains(_, "cookie"))
  assert !list.any(paths, string.contains(_, "ledger"))
}

pub fn an_untrusted_launch_forwards_the_port_and_registers_no_node_test() {
  let launch = launch(vm_spec.Forward)
  let arguments = vm_spec.launch_arguments(launch)

  assert list.contains(arguments, "--forward")
  assert list.contains(arguments, "47011:4370")
  assert !list.contains(arguments, "--publish")
}

pub fn a_distribution_launch_still_publishes_the_node_test() {
  let arguments = vm_spec.launch_arguments(launch(vm_spec.Publish))

  assert list.contains(arguments, "--publish")
  assert list.contains(arguments, "loom_vm_dev_exec:47011:4370")
  assert !list.contains(arguments, "--forward")
}

fn launch(reach: vm_spec.Reach) -> vm_spec.Launch {
  vm_spec.Launch(
    manifest: vm_spec.Manifest(
      revision: "abc1234",
      loom_vm: "/h/loom-vm",
      runner: "/h/runner",
      lib_dir: "/h/lib",
      firmware_dir: None,
      guest_root: "/h/root",
    ),
    names: vm_spec.names("dev"),
    root: "/vm/dev/root",
    memory_mib: 2048,
    cpus: 2,
    host_port: 47_011,
    state_disk: "/vm/dev/state.img",
    github: vm_spec.GitHubOff,
    allow: [],
    reach:,
  )
}

pub fn the_status_lines_name_the_link_and_the_address_test() {
  let lines = vm_link.status_lines(Some(41_000), Some(pin_a))
  assert lines
    == [
      "link:       untrusted, TLS to 127.0.0.1:41000",
      "pin:        " <> pin_a,
    ]
}

pub fn an_untrusted_guest_is_serving_when_its_console_says_so_test() {
  assert vm_link.registration("booting\nLOOM-EXECUTOR-READY untrusted\n")
    == vm_spec.Registered
  assert vm_link.registration("booting\n") == vm_spec.Unregistered
}

// --- the credentials ---------------------------------------------------------------------

fn mode_of(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path) as "the path is there"
  int.bitwise_and(info.mode, 0o777)
}

pub fn the_credentials_are_private_whole_and_kept_between_calls_test() {
  let vm_home = fixtures.scratch("vm-link-pki")
  let assert Ok(home) = vm_link_pki.ensure_home(vm_home)
  let assert Ok(leaf) = vm_link_pki.ensure_leaf(home, vm_home <> "/dev")

  // Every file is 0600 and every directory 0700.
  assert mode_of(home.files.ca) == 0o600
  assert mode_of(home.files.key) == 0o600
  assert mode_of(home.ca_key) == 0o600
  assert mode_of(vm_home <> "/link") == 0o700
  assert mode_of(vm_home <> "/dev/link-credentials") == 0o700
  assert mode_of(vm_home <> "/dev/link-credentials/executor.key") == 0o600

  // A second call reads what the first made, so a resume keeps the pin the
  // daemon's row holds; another guest gets another leaf under the same
  // authority.
  let assert Ok(again) = vm_link_pki.ensure_home(vm_home)
  let assert Ok(same) = vm_link_pki.ensure_leaf(again, vm_home <> "/dev")
  let assert Ok(other) = vm_link_pki.ensure_leaf(again, vm_home <> "/other")
  assert again.pin == home.pin
  assert same.pin == leaf.pin
  assert other.pin != leaf.pin
  assert vm_link_pki.files_of(vm_home) == home.files
}

pub fn an_interrupted_mint_leaves_nothing_a_later_call_trusts_test() {
  let vm_home = fixtures.scratch("vm-link-interrupted")
  let assert Ok(Nil) =
    simplifile.create_directory_all(vm_home <> "/link.minting")
  let assert Ok(Nil) =
    simplifile.write(vm_home <> "/link.minting/ca.pem", "half")

  // The half-built directory is removed and built again, whole.
  let assert Ok(home) = vm_link_pki.ensure_home(vm_home)
  assert simplifile.is_file(home.files.ca) == Ok(True)
  assert simplifile.is_directory(vm_home <> "/link.minting") == Ok(False)
}

pub fn a_credentials_directory_missing_a_file_is_refused_not_repaired_test() {
  let vm_home = fixtures.scratch("vm-link-torn")
  let assert Ok(home) = vm_link_pki.ensure_home(vm_home)
  let assert Ok(Nil) = simplifile.delete(home.ca_key)

  let assert Error(reason) = vm_link_pki.ensure_home(vm_home)
  assert string.contains(reason, "ca.key")
}

// The minted credentials are used for a real handshake that pins the leaf the
// way the link does: the executor admits the orchestrator's pin and the
// orchestrator expects the executor's.
pub fn the_minted_credentials_complete_a_pinned_handshake_test() {
  let vm_home = fixtures.scratch("vm-link-handshake")
  let assert Ok(home) = vm_link_pki.ensure_home(vm_home)
  let assert Ok(leaf) = vm_link_pki.ensure_leaf(home, vm_home <> "/dev")
  let assert Ok(stranger) = vm_link_pki.ensure_leaf(home, vm_home <> "/stray")

  let executor = vm_home <> "/dev/link-credentials"
  let credentials =
    ffi_tls_stream.Credentials(
      ca: home.files.ca,
      certificate: executor <> "/executor.pem",
      key: executor <> "/executor.key",
    )
  let orchestrator =
    ffi_tls_stream.Credentials(
      ca: home.files.ca,
      certificate: home.files.certificate,
      key: home.files.key,
    )
  let assert Ok(admitted) = untrusted_config.pin_of(home.pin, "orchestrator")
  let assert Ok(expected) = untrusted_config.pin_of(leaf.pin, "executor")
  let assert Ok(wrong) = untrusted_config.pin_of(stranger.pin, "stranger")
  let #(listener, port) = rig.listen(credentials, [admitted])

  // The orchestrator dials with the right pin and is admitted.
  let outcome = process.new_subject()
  let _dialler =
    process.spawn(fn() {
      process.send(
        outcome,
        result.is_ok(rig.dial(port, orchestrator, expected)),
      )
    })
  let _stream = rig.accept(listener)
  let assert Ok(True) = process.receive(outcome, 10_000)

  // A dial that expects another guest's pin is refused by the orchestrator's
  // own check. The listener's side of that handshake is run in a process of
  // its own, because the dial cannot finish until it is.
  let _listening =
    process.spawn_unlinked(fn() {
      case ffi_tls_stream.accept(listener, 10_000) {
        Ok(raw) -> {
          let _handshake = ffi_tls_stream.handshake(raw, 10_000)
          Nil
        }
        Error(_) -> Nil
      }
    })
  assert result.is_error(rig.dial(port, orchestrator, wrong))
}
