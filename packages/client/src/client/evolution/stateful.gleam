//// A stateful generation shares its existing jail, host registry and native
//// retirement capability. New source goes through the same compiler and seam;
//// only the exact authored fixed-slot BEAM set travels to the trusted loader.

import client/evolution/evaluate
import client/evolution/live
import client/evolution/record
import client/evolution/store
import client/extension/dispatch
import client/extension/hosts
import client/extension/live_contract
import codemode/beam_atoms
import codemode/live_slots
import codemode/vet/package
import core/json
import core/msgpack
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/blob

/// Native compiler custody remains separate from source-owned declarations.
pub type Compiler =
  fn(record.CandidateId, String, live_slots.Slot) ->
    Result(evaluate.Prepared, store.Refusal)

type Context {
  Context(
    catalogue: store.Store,
    dispatch: dispatch.Config,
    hosting: hosts.Hosts,
    prepared: evaluate.Prepared,
    contract: live_contract.Contract,
    slot: live_slots.Slot,
    compile: Compiler,
    at: hosts.Coordinates,
    root: String,
    atom_baseline: List(String),
    inventory: fn() -> Result(json.JsonValue, String),
  )
}

/// Attaches live activation only when the immutable source explicitly opts in.
///
/// ## Examples
///
/// ```gleam
/// // stateful.attach(generation, store, dispatch, hosting, prepared, compile)
/// ```
///
pub fn attach(
  generation: live.Generation,
  catalogue: store.Store,
  dispatch: dispatch.Config,
  hosting: hosts.Hosts,
  prepared: evaluate.Prepared,
  compile: Compiler,
  at: hosts.Coordinates,
) -> Result(live.Generation, store.Refusal) {
  use contract <- result.try(contract(prepared))
  case contract {
    None -> Ok(generation)
    Some(contract) -> {
      use compiled <- result.try(compiled(prepared, live_slots.First))
      Ok(with_mode(
        generation,
        Context(
          catalogue,
          dispatch,
          hosting,
          prepared,
          contract,
          live_slots.First,
          compile,
          at,
          prepared.directory,
          compiled.1,
          generation.inventory,
        ),
      ))
    }
  }
}

fn with_mode(generation: live.Generation, context: Context) -> live.Generation {
  let baseline =
    live.Generation(
      ..generation,
      mode: live.ReplacementOnly,
      inventory: context.inventory,
    )
  let inventory = context.inventory
  live.Generation(
    ..baseline,
    inventory: fn() {
      use native <- result.try(inventory())
      use status <- result.try(
        control(context, "__loom_live_status", msgpack.MapValue([]))
        |> result.map_error(string.inspect),
      )
      let live_status =
        json.Object(
          list.map(
            ["pending", "last", "last_status", "version", "slot", "state_pid"],
            fn(key) {
              #(key, json.String(status_text(status, key) |> result.unwrap("")))
            },
          ),
        )
      case native {
        json.Object(fields) ->
          Ok(json.Object(list.append(fields, [#("live", live_status)])))
        _ -> Ok(json.Object([#("native", native), #("live", live_status)]))
      }
    },
    mode: live.Stateful(fn(selection) { prepare(baseline, context, selection) }),
  )
}

fn prepare(
  current: live.Generation,
  context: Context,
  selection: record.Selection,
) -> Result(live.PreparedUpgrade, store.Refusal) {
  use _ <- result.try(store.approved(context.catalogue, selection))
  let slot = case context.slot {
    live_slots.First -> live_slots.Second
    live_slots.Second -> live_slots.First
  }
  let directory =
    context.root <> "/live-" <> int.to_string(selection.generation)
  use prepared <- result.try(context.compile(
    selection.candidate_id,
    directory,
    slot,
  ))
  use declared <- result.try(contract(prepared))
  use target <- result.try(case declared {
    Some(contract) -> Ok(contract)
    None ->
      Error(store.Bounds(
        "stateful component requires an explicit compatible live contract",
      ))
  })
  use Nil <- result.try(
    live_contract.compatible(
      context.contract,
      target,
      context.contract.state_version,
    )
    |> result.map_error(store.Bounds),
  )
  use Nil <- result.try(
    case
      target.pause_ms == context.contract.pause_ms
      && target.max_state_bytes == context.contract.max_state_bytes
      && prepared.manifest.name == context.prepared.manifest.name
      && prepared.manifest.net == context.prepared.manifest.net
      && prepared.manifest.hooks == context.prepared.manifest.hooks
      && module_names(prepared) == module_names(context.prepared)
    {
      True -> Ok(Nil)
      False ->
        Error(store.Bounds(
          "live upgrade changes capability policy or the fixed authored module set",
        ))
    },
  )
  use compiled <- result.try(compiled(prepared, slot))
  let modules = compiled.0
  let transition =
    record.id_string(selection.candidate_id)
    <> ":"
    <> int.to_string(selection.generation)
  let payload = control_payload(context, target, slot, transition, modules)
  use _ <- result.try(control(context, "__loom_live_prepare", payload))
  use tools <- result.try(
    dispatch.tools(
      context.dispatch,
      prepared.record,
      prepared.manifest,
      prepared.sources,
      prepared.artifact,
    )
    |> result.map_error(store.Unavailable),
  )
  let catalogue = context.catalogue
  let successor =
    live.Generation(..current, selection:, tools:, validate: fn() {
      store.authorized(catalogue, selection) |> result.replace(Nil)
    })
  let next = Context(..context, prepared:, contract: target, slot:)
  Ok(
    live.PreparedUpgrade(
      generation: with_mode(successor, next),
      publish: fn() { publish(context, transition, payload) },
      abort: fn() {
        control(context, "__loom_live_abort", transition_payload(transition))
        |> result.replace(Nil)
      },
    ),
  )
}

fn publish(
  context: Context,
  transition: String,
  payload: msgpack.MsgPackValue,
) -> Result(Nil, store.Refusal) {
  // A missing acknowledgement leaves native custody unresolved. One bounded
  // reconciliation pass reads the satellite receipt before issuing anything
  // again; an acknowledged commit cannot migrate the component twice.
  case publish_once(context, transition, payload) {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> publish_once(context, transition, payload)
  }
}

fn publish_once(
  context: Context,
  transition: String,
  payload: msgpack.MsgPackValue,
) -> Result(Nil, store.Refusal) {
  use status <- result.try(control(
    context,
    "__loom_live_status",
    msgpack.MapValue([]),
  ))
  let committed =
    status_text(status, "last") == Ok(transition)
    && status_text(status, "last_status") == Ok("committed")
  case committed {
    True -> Ok(Nil)
    False -> {
      let pending = status_text(status, "pending") == Ok(transition)
      use Nil <- result.try(case pending {
        True -> Ok(Nil)
        False ->
          control(context, "__loom_live_prepare", payload)
          |> result.replace(Nil)
      })
      use result <- result.try(control(
        context,
        "__loom_live_commit",
        transition_payload(transition),
      ))
      case
        status_text(result, "last") == Ok(transition)
        && status_text(result, "last_status") == Ok("committed")
      {
        True -> Ok(Nil)
        False ->
          Error(store.Unavailable(
            "native selection committed but live publication receipt is unresolved",
          ))
      }
    }
  }
}

fn control(
  context: Context,
  event: String,
  payload: msgpack.MsgPackValue,
) -> Result(msgpack.MsgPackValue, store.Refusal) {
  hosts.invoke_event(
    context.hosting,
    extension: context.prepared.record.name,
    event:,
    args: payload,
    at: context.at,
    within: 10_000,
  )
  |> result.map_error(fn(error) { store.Unavailable(string.inspect(error)) })
}

fn contract(
  prepared: evaluate.Prepared,
) -> Result(Option(live_contract.Contract), store.Refusal) {
  use text <- result.try(
    list.key_find(prepared.candidate.files, "extension.toml")
    |> result.replace_error(store.Bounds("extension.toml absent")),
  )
  live_contract.decode(text, module_names(prepared))
  |> result.map_error(store.Bounds)
}

fn module_names(prepared: evaluate.Prepared) -> List(String) {
  prepared.candidate.files
  |> list.map(fn(file) {
    case string.starts_with(file.0, "test/") {
      True -> #("src/" <> string.drop_start(file.0, 5), file.1)
      False -> file
    }
  })
  |> package.module_names_of
}

fn compiled(
  prepared: evaluate.Prepared,
  slot: live_slots.Slot,
) -> Result(#(List(msgpack.MsgPackValue), List(String)), store.Refusal) {
  let paths =
    list.map(module_names(prepared), fn(module) {
      let name = live_slots.module(slot, module) |> string.replace("/", "@")
      #(name, prepared.artifact <> "/" <> name <> ".beam")
    })
  use Nil <- result.try(case list.is_empty(list.drop(paths, 16)) {
    True -> Ok(Nil)
    False -> Error(store.Bounds("live module set exceeds sixteen modules"))
  })

  // Stat before reading to bound both retained bytes and parser work.
  use sizes <- result.try(
    list.try_map(paths, fn(file) {
      simplifile.file_info(file.1)
      |> result.map(fn(info) { info.size })
      |> result.map_error(fn(error) {
        store.Unavailable(simplifile.describe_error(error))
      })
    }),
  )
  use Nil <- result.try(
    case
      list.fold(sizes, 0, fn(total, size) { total + size }) <= 2_097_152
      && list.is_empty(list.drop(paths, 16))
    {
      True -> Ok(Nil)
      False ->
        Error(store.Bounds(
          "live compiled artifact exceeds native module or byte budget",
        ))
    },
  )
  use captured <- result.try(
    list.try_map(paths, fn(file) {
      use bytes <- result.try(
        simplifile.read_bits(file.1)
        |> result.map_error(fn(error) {
          store.Unavailable(simplifile.describe_error(error))
        }),
      )
      use atoms <- result.try(
        beam_atoms.read(bytes) |> result.map_error(store.Bounds),
      )
      Ok(#(
        msgpack.MapValue([
          #(msgpack.StringValue("name"), msgpack.StringValue(file.0)),
          #(msgpack.StringValue("bytes"), msgpack.BinaryValue(bytes)),
          #(
            msgpack.StringValue("digest"),
            msgpack.StringValue(blob.ref_for(bytes)),
          ),
        ]),
        atoms,
        bit_array.byte_size(bytes),
      ))
    }),
  )
  let atoms = list.flat_map(captured, fn(module) { module.1 }) |> list.unique
  use Nil <- result.try(
    case
      list.is_empty(list.drop(atoms, 4096))
      && list.fold(atoms, 0, fn(size, atom) { size + string.byte_size(atom) })
      <= 131_072
      && list.fold(captured, 0, fn(size, module) { size + module.2 })
      <= 2_097_152
    {
      True -> Ok(Nil)
      False ->
        Error(store.Bounds(
          "live artifact exceeds its native atom or byte budget",
        ))
    },
  )
  Ok(#(list.map(captured, fn(module) { module.0 }), atoms))
}

fn control_payload(
  context: Context,
  target: live_contract.Contract,
  slot: live_slots.Slot,
  transition: String,
  modules: List(msgpack.MsgPackValue),
) -> msgpack.MsgPackValue {
  let named = fn(module) {
    live_slots.module(slot, module) |> string.replace("/", "@")
  }
  let slot = case slot {
    live_slots.First -> "a"
    live_slots.Second -> "b"
  }
  msgpack.MapValue([
    #(msgpack.StringValue("transition"), msgpack.StringValue(transition)),
    #(
      msgpack.StringValue("from"),
      msgpack.StringValue(context.contract.state_version),
    ),
    #(msgpack.StringValue("version"), msgpack.StringValue(target.state_version)),
    #(msgpack.StringValue("boundary"), msgpack.StringValue(target.boundary)),
    #(msgpack.StringValue("slot"), msgpack.StringValue(slot)),
    #(msgpack.StringValue("entry"), msgpack.StringValue(named(target.entry))),
    #(
      msgpack.StringValue("migration"),
      msgpack.StringValue(named(target.migration)),
    ),
    #(msgpack.StringValue("modules"), msgpack.ArrayValue(modules)),
    #(
      msgpack.StringValue("atom_baseline"),
      msgpack.ArrayValue(list.map(context.atom_baseline, msgpack.StringValue)),
    ),
  ])
}

fn transition_payload(transition: String) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("transition"), msgpack.StringValue(transition)),
  ])
}

fn status_text(
  value: msgpack.MsgPackValue,
  key: String,
) -> Result(String, Nil) {
  case value {
    msgpack.MapValue(fields) -> {
      use value <- result.try(list.key_find(fields, msgpack.StringValue(key)))
      case value {
        msgpack.StringValue(text) -> Ok(text)
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}
