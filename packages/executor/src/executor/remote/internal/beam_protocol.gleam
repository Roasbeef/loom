//// Closed byte vocabulary for the trusted TLS-BEAM executor endpoint.
////
//// The transport header chooses native execution or semantic workspace work.
//// Its Hello retains the exact existing labels, scope and generation. Native
//// and workspace payload codecs remain the durable canonical representation;
//// neither a process reference nor this header becomes an effect identity.
//// Transfer bounds apply before content is retained, and a control lane cannot
//// be used to sneak a first Submit past the reserved data admission window.

import executor/remote/compile_wire
import executor/remote/identity
import executor/remote/launch_wire
import executor/remote/wire
import executor/remote/workspace_journal as journal
import executor/remote/workspace_transfer as transfer
import gleam/bit_array
import gleam/bool
import gleam/result

/// A fixed class of ingress capacity.
@internal
pub type Lane {
  /// First admission and native input share the data window.
  Data

  /// Query, cancellation and receipt have independently reserved capacity.
  Control
}

/// One closed semantic operation, retaining its original invocation bytes.
pub type WorkspaceCommand {
  /// Reserve and claim the original invocation at most once.
  Submit

  /// Observe the original invocation without a new claim.
  Query

  /// Record the owner receipt for the exact retained completion digest.
  Acknowledge(digest: identity.Digest)
}

/// Closed routes into concrete registered native, workspace and Compile owners.
@internal
pub type Route {
  /// Exact native payload with a checked ingress class.
  Native(lane: Lane)

  /// Exact semantic payload with a closed operation.
  Workspace(command: WorkspaceCommand)

  /// Whole Compile operation with unchanged canonical command bytes.
  Compile(command: compile_wire.Command)

  /// Closed finite Launch metadata, without live stream admission.
  Launch(command: launch_wire.Command)

  /// Physical command routed by its original live whole-service Claim.
  NativeCommand(lane: Lane)
}

/// Exact administrative configuration used by both codec directions.
@internal
pub type Binding {
  Binding(
    /// Provisioned owner label, never a peer-selected principal.
    owner: String,
    /// Provisioned executor label under the full scope.
    executor: String,
    /// The admitted transient transport generation.
    generation: Int,
    /// Complete original session and workspace authority epochs.
    scope: identity.Scope,
  )
}

/// Chooses capacity from the actual closed native request body.
///
/// ## Examples
/// `lane(wire.Hello)` returns `Ok(Control)`.
@internal
pub fn lane(body: wire.Body) -> Result(Lane, Nil) {
  case body {
    wire.ChallengeRequest(_, _)
    | wire.Submit(_, _, _, _, _)
    | wire.Stdin(_, _, _, _, _) -> Ok(Data)
    wire.Hello
    | wire.Query(_, _, _)
    | wire.Cancel(_, _)
    | wire.DurableReceipt(_, _, _)
    | wire.CloseScope
    | wire.ScopeRetirement -> Ok(Control)
    wire.Challenge(_, _, _, _)
    | wire.Evidence(_, _, _, _)
    | wire.Output(_, _, _, _)
    | wire.Terminal(_, _, _)
    | wire.Rejected(_) -> Error(Nil)
  }
}

/// The semantic command fixes its capacity class before transfer.
///
/// ## Examples
/// `route_lane(Workspace(Query))` returns `Control`.
@internal
pub fn route_lane(route: Route) -> Lane {
  case route {
    Native(lane) -> lane
    Workspace(Submit) -> Data
    Workspace(Query) | Workspace(Acknowledge(_)) -> Control
    Compile(compile_wire.ChallengeRequest)
    | Compile(compile_wire.Submit(_, _)) -> Data
    Compile(compile_wire.Query)
    | Compile(compile_wire.Cancel)
    | Compile(compile_wire.Acknowledge(_)) -> Control
    Launch(launch_wire.ChallengeRequest)
    | Launch(launch_wire.PlaceToken(_, _)) -> Data
    Launch(launch_wire.Query)
    | Launch(launch_wire.Cancel)
    | Launch(launch_wire.Acknowledge(_))
    | Launch(launch_wire.RefuseBeforeNative) -> Control
    NativeCommand(lane) -> lane
  }
}

/// Encodes a small versioned header with the unchanged canonical Hello.
///
/// ## Examples
/// `header(binding, Native(Control))` prepares a native observer header.
@internal
pub fn header(binding: Binding, route: Route) -> Result(BitArray, Nil) {
  use hello <- result.try(
    wire.encode(envelope(binding, wire.Owner, wire.Hello))
    |> result.replace_error(Nil),
  )
  use prefix <- result.try(case route {
    Native(Data) -> Ok(<<1, 0, 0>>)
    Native(Control) -> Ok(<<1, 0, 1>>)
    Workspace(Submit) -> Ok(<<1, 1, 0>>)
    Workspace(Query) -> Ok(<<1, 1, 1>>)
    Workspace(Acknowledge(digest)) ->
      Ok(<<
        1,
        1,
        2,
        identity.digest_bytes(digest):bits,
      >>)
    Compile(command) ->
      compile_wire.encode_command(command)
      |> result.map(fn(bytes) { <<1, 2, bytes:bits>> })
      |> result.replace_error(Nil)
    Launch(operation) ->
      launch_wire.encode_command(operation)
      |> result.map(fn(bytes) { <<1, 4, bytes:bits>> })
      |> result.replace_error(Nil)
    NativeCommand(Data) -> Ok(<<1, 3, 0>>)
    NativeCommand(Control) -> Ok(<<1, 3, 1>>)
  })
  Ok(<<prefix:bits, hello:bits>>)
}

/// Decodes against one exact provisioned binding before granting a credit.
///
/// ## Examples
/// `decode_header(binding, <<>>) == Error(Nil)`.
@internal
pub fn decode_header(binding: Binding, bytes: BitArray) -> Result(Route, Nil) {
  use <- bool.guard(bit_array.byte_size(bytes) > 1024, Error(Nil))
  use #(route, hello) <- result.try(case bytes {
    <<1, 0, 0, hello:bytes>> -> Ok(#(Native(Data), hello))
    <<1, 0, 1, hello:bytes>> -> Ok(#(Native(Control), hello))
    <<1, 1, 0, hello:bytes>> -> Ok(#(Workspace(Submit), hello))
    <<1, 1, 1, hello:bytes>> -> Ok(#(Workspace(Query), hello))
    <<1, 1, 2, digest:bytes-size(32), hello:bytes>> -> {
      use digest <- result.try(
        identity.digest(digest) |> result.replace_error(Nil),
      )
      Ok(#(Workspace(Acknowledge(digest)), hello))
    }
    <<1, 2, "LCQ", 1, 0, hello:bytes>> ->
      Ok(#(Compile(compile_wire.ChallengeRequest), hello))
    <<1, 2, "LCQ", 1, 1, nonce:bytes-size(32), budget:32, hello:bytes>> -> {
      use command <- result.try(
        compile_wire.decode_command(<<"LCQ", 1, 1, nonce:bits, budget:32>>)
        |> result.replace_error(Nil),
      )
      Ok(#(Compile(command), hello))
    }
    <<1, 2, "LCQ", 1, 2, hello:bytes>> ->
      Ok(#(Compile(compile_wire.Query), hello))
    <<1, 2, "LCQ", 1, 3, hello:bytes>> ->
      Ok(#(Compile(compile_wire.Cancel), hello))
    <<1, 2, "LCQ", 1, 4, digest:bytes-size(32), hello:bytes>> -> {
      use digest <- result.try(
        identity.digest(digest) |> result.replace_error(Nil),
      )
      Ok(#(Compile(compile_wire.Acknowledge(digest)), hello))
    }
    <<1, 4, "LLQ", 1, 0, hello:bytes>> ->
      Ok(#(Launch(launch_wire.ChallengeRequest), hello))
    <<1, 4, "LLQ", 1, 1, nonce:bytes-size(32), budget:32, hello:bytes>> -> {
      use operation <- result.try(
        launch_wire.decode_command(<<"LLQ", 1, 1, nonce:bits, budget:32>>)
        |> result.replace_error(Nil),
      )
      Ok(#(Launch(operation), hello))
    }
    <<1, 4, "LLQ", 1, 2, hello:bytes>> ->
      Ok(#(Launch(launch_wire.Query), hello))
    <<1, 4, "LLQ", 1, 3, hello:bytes>> ->
      Ok(#(Launch(launch_wire.Cancel), hello))
    <<1, 4, "LLQ", 1, 4, digest:bytes-size(32), hello:bytes>> -> {
      use digest <- result.try(
        identity.digest(digest) |> result.replace_error(Nil),
      )
      Ok(#(Launch(launch_wire.Acknowledge(digest)), hello))
    }
    <<1, 4, "LLQ", 1, 5, hello:bytes>> ->
      Ok(#(Launch(launch_wire.RefuseBeforeNative), hello))
    <<1, 3, 0, hello:bytes>> -> Ok(#(NativeCommand(Data), hello))
    <<1, 3, 1, hello:bytes>> -> Ok(#(NativeCommand(Control), hello))
    _ -> Error(Nil)
  })
  use decoded <- result.try(native(binding, wire.Owner, hello))
  use <- bool.guard(decoded.body != wire.Hello, Error(Nil))
  use exact <- result.try(header(binding, route))
  case exact == bytes {
    True -> Ok(route)
    False -> Error(Nil)
  }
}

/// Constructs an existing native envelope without changing custody bytes.
///
/// ## Examples
/// `envelope(binding, wire.Executor, wire.Hello)` answers the handshake.
@internal
pub fn envelope(
  binding: Binding,
  role: wire.Role,
  body: wire.Body,
) -> wire.Envelope {
  wire.Envelope(
    role,
    binding.owner,
    binding.executor,
    binding.generation,
    binding.scope,
    body,
  )
}

/// Pins native role, labels, scope, generation and exact canonical encoding.
///
/// ## Examples
/// `native(binding, wire.Owner, <<>>) == Error(Nil)`.
@internal
pub fn native(
  binding: Binding,
  role: wire.Role,
  bytes: BitArray,
) -> Result(wire.Envelope, Nil) {
  use decoded <- result.try(
    wire.decode(bytes, role, binding.owner, binding.executor, binding.scope)
    |> result.replace_error(Nil),
  )
  use exact <- result.try(wire.encode(decoded) |> result.replace_error(Nil))
  case decoded.generation == binding.generation && exact == bytes {
    True -> Ok(decoded)
    False -> Error(Nil)
  }
}

/// Refuses a native aggregate before accepting its first body chunk.
///
/// ## Examples
/// `receiver(Native(Data), transfer.Invocation, <<>>) == Error(Nil)`.
@internal
pub fn receiver(
  route: Route,
  kind: transfer.Kind,
  bytes: BitArray,
) -> Result(transfer.Receiver, Nil) {
  use total <- result.try(case bytes {
    <<"LWC", 1, _direction, total:32, _digest:bytes-size(32)>> -> Ok(total)
    _ -> Error(Nil)
  })
  use <- bool.guard(
    total < 1
      || case route {
      Native(_) | NativeCommand(_) -> total > 262_144
      Compile(_) | Launch(_) ->
        case kind {
          transfer.Invocation -> total > 9_437_184
          transfer.Completion | transfer.CompileCompletion -> total > 524_300
        }
      Workspace(_) -> False
    },
    Error(Nil),
  )
  transfer.begin_receive(kind, bytes) |> result.replace_error(Nil)
}

/// Encodes the workspace status without a socket-dependent envelope.
///
/// ## Examples
/// `status(journal.Unknown) == <<1, 1>>`.
@internal
pub fn status(status: journal.Status) -> BitArray {
  case status {
    journal.Accepted -> <<1, 0>>
    journal.Unknown -> <<1, 1>>
    journal.Finished(bytes) -> <<1, 2, bytes:bits>>
    journal.Acknowledged(digest) -> <<1, 3, digest:bits>>
    journal.Cancelled -> <<1, 4>>
  }
}

/// Decodes only the closed statuses; semantic completion checking follows.
///
/// ## Examples
/// `decode_status(<<1, 1>>) == Ok(journal.Unknown)`.
@internal
pub fn decode_status(bytes: BitArray) -> Result(journal.Status, Nil) {
  case bytes {
    <<1, 0>> -> Ok(journal.Accepted)
    <<1, 1>> -> Ok(journal.Unknown)
    <<1, 2, bytes:bytes>> -> Ok(journal.Finished(bytes))
    <<1, 3, digest:bytes-size(32)>> -> Ok(journal.Acknowledged(digest))
    <<1, 4>> -> Ok(journal.Cancelled)
    _ -> Error(Nil)
  }
}
