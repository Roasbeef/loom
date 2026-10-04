//// Closed semantic codec conformance and adversarial allocation admission.
////
//// Real-disk completions establish that the wire projections retain the
//// existing host's results. Mutation cases cross the actual binary decoder;
//// preflight tests isolate resource admission before msgpack term allocation.
////
//// ## Flow
////
//// `every_request_retains_full_identity_and_canonical_bytes_test` fixes identity
//// fidelity; failure_fields_remain_distinct_and_loss_remains_unknown_test keeps
//// refusal semantics; `allocation_preflight_exact_limits_and_claimed_lengths_test`
//// checks the allocation boundary; `actual_local_file_results_survive_codec_without_projection_loss_test`
//// compares real host effects; `maximal_landed_edit_plus_max_diagnostics_fits_reserved_completion_test`
//// proves that successful mutation evidence fits its byte reservation.
//// `nested` constructs scanner-only depth probes; `git_error` keeps broker
//// refusals on the same expected Git projection.

import broker/broker
import broker/budget
import broker/escalation
import broker/exec
import broker/framing
import broker/policy
import broker/token
import core/corruption
import core/ids
import core/msgpack
import core/workspace as cw
import gleam/bit_array
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile
import support/fake_broker
import tools/fs
import tools/hashline
import tools/search
import tools/tool
import tools/workspace as w
import tools/workspace_codec as codec
import tools/workspace_codec/preflight
import tools/workspace_codec/value
import tools/workspace_local as local

pub fn every_request_retains_full_identity_and_canonical_bytes_test() {
  let a = hashline.Ref(1, hashline.anchor("a"))
  let b = hashline.Ref(2, hashline.anchor("b"))
  let plan =
    hashline.Plan(hashline.digest("a\nb\n"), [
      hashline.Replace(a, b, ["é", "\r"]),
      hashline.Delete(a, b),
      hashline.InsertAfter(b, ["later"]),
      hashline.InsertAtStart(["first"]),
    ])

  // The retained request selects the completion projection.
  let requests = [
    w.Read(path("src/a"), w.Text),
    w.Read(path("src/a"), w.Native(5, 3)),
    w.Read(path("src/a"), w.Lines(2, 7)),
    w.Write(path("src/a"), "nul\u{0000}é\r\n"),
    w.AnchoredEdit(path("src/a"), plan),
    w.ListEntries(cw.root(), glob()),
    w.Search(path("src"), grep()),
    w.Stat(path("src/a")),
    w.Git(w.CurrentBranch),
    w.Git(w.CurrentRevision),
    w.Git(w.Status),
    w.Git(w.Diff(w.WorkingTree)),
    w.Git(w.Diff(w.Staged)),
    w.Git(w.Diff(w.SinceRevision(revision()))),
    w.Git(w.Log(1000)),
    w.Guidance,
    w.Initialize,
  ]
  list.each(requests, fn(request) {
    let call = invocation(request)
    let assert Ok(bytes) = codec.encode_invocation(call) as "valid invocation"
    assert codec.decode_invocation(bytes) == Ok(call)
    let assert Ok(decoded) = codec.decode_invocation(bytes)
      as "decode canonical bytes"
    assert codec.encode_invocation(decoded) == Ok(bytes)
  })

  // Every origin has its own wire discriminant, without fabricated tool indices.
  let callers = [
    w.CommandPreparation,
    w.Compiler,
    w.SatelliteLaunch,
    w.LanguageServer,
    w.WorktreeObservation,
    w.WorkspaceAdministration,
  ]
  let #(scope, operation, step, _, id) =
    w.invocation_identity(invocation(w.Initialize))
  list.each(callers, fn(caller) {
    let call =
      w.invocation(scope, operation, step, w.System(caller), id, w.Initialize)
    let assert Ok(bytes) = codec.encode_invocation(call) as "system origin"
    assert codec.decode_invocation(bytes) == Ok(call)
  })
}

pub fn all_response_projections_and_binary_images_roundtrip_test() {
  let lines = hashline.annotate("a\nb\n")
  let pairs = [
    #(w.Read(path("a"), w.Text), w.ReadCompleted(Ok(w.TextRead("a\r\n")))),
    #(
      w.Read(path("a"), w.Native(2, 1)),
      w.ReadCompleted(
        Ok(w.AnchoredRead(
          hashline.digest("a\nb\n"),
          hashline.window("a\nb\n", 2, 1),
        )),
      ),
    ),
    #(
      w.Read(path("a"), w.Lines(2, 9)),
      w.ReadCompleted(Ok(w.LinesRead(search.Lines("b", 2, 2, 2)))),
    ),
    #(
      w.Write(path("a"), "a\nb\n"),
      w.WriteCompleted(
        Ok(w.Written(4, hashline.digest("a\nb\n"), w.Included(lines))),
      ),
    ),
    #(
      w.Write(path("a"), "big"),
      w.WriteCompleted(
        Ok(w.Written(3, hashline.digest("big"), w.RequiresWindowedRead)),
      ),
    ),
    #(
      w.AnchoredEdit(path("a"), plan()),
      w.EditCompleted(Ok(fs.Landed("a\n", "A\n"))),
    ),
    #(
      w.ListEntries(cw.root(), glob()),
      w.ListingCompleted(
        Ok(search.Listing(
          [
            search.Entry("a", search.File, 7, -1),
            search.Entry("dir", search.Directory, 0, 123),
            search.Entry("link", search.Symlink("/outside/observed"), 11, 123),
            search.Entry("socket", search.Other, 0, 123),
          ],
          search.Truncated,
        )),
      ),
    ),
    #(
      w.Search(cw.root(), grep()),
      w.SearchCompleted(
        Ok(search.Found(
          [search.Match("a", 2, 3, "needle", ["before"], ["after"])],
          17,
          4,
          search.ScanTruncated,
        )),
      ),
    ),
    #(
      w.Stat(path("a")),
      w.StatCompleted(Ok(search.Entry("a", search.File, 9, 123))),
    ),
    #(w.Git(w.CurrentBranch), w.GitCompleted(Ok(w.BranchObserved("topic")))),
    #(w.Git(w.CurrentRevision), w.GitCompleted(Ok(w.RevisionObserved(None)))),
    #(
      w.Git(w.CurrentRevision),
      w.GitCompleted(Ok(w.RevisionObserved(Some(revision())))),
    ),
    #(
      w.Git(w.Status),
      w.GitCompleted(Ok(w.StatusObserved([w.GitStatusEntry("??", "a")]))),
    ),
    #(w.Git(w.Diff(w.Staged)), w.GitCompleted(Ok(w.DiffObserved("diff\n")))),
    #(
      w.Git(w.Log(2)),
      w.GitCompleted(
        Ok(
          w.LogObserved([w.GitCommit(w.revision_string(revision()), "subject")]),
        ),
      ),
    ),
    #(
      w.Guidance,
      w.GuidanceCompleted(
        Ok(w.GuidanceLoaded(
          [w.GuidanceFile(path("AGENTS.md"), "rules")],
          search.Complete,
        )),
      ),
    ),
    #(w.Initialize, w.InitializationCompleted(Ok(w.Initialized))),
    #(w.Initialize, w.InitializationCompleted(Ok(w.AlreadyInitialized))),
  ]
  list.each(pairs, fn(pair) {
    roundtrip(
      pair.0,
      Ok(local.Completed(pair.1, Some("settled\u{0000}diagnostic"))),
    )
  })
  list.each(
    [
      #(<<0x89, "PNG", 13, 10, 26, 10, 0, 255>>, w.Png),
      #(<<255, 216, 255, 0>>, w.Jpeg),
      #(<<"GIF89a", 0, 255>>, w.Gif),
      #(<<"RIFF", 0:size(32), "WEBP", 255>>, w.Webp),
    ],
    fn(image) {
      roundtrip(
        w.Read(path("a"), w.Native(1, 1)),
        Ok(local.Completed(
          w.ReadCompleted(Ok(w.ImageRead(image.0, image.1))),
          None,
        )),
      )
    },
  )
  list.each(
    [search.Exhaustive, search.MatchesCapped, search.ScanTruncated],
    fn(coverage) {
      roundtrip(
        w.Search(cw.root(), grep()),
        Ok(local.Completed(
          w.SearchCompleted(Ok(search.Found([], 0, 1, coverage))),
          None,
        )),
      )
    },
  )
}

pub fn failure_fields_remain_distinct_and_loss_remains_unknown_test() {
  let fs_errors = [
    tool.FsNotFound("/physical/a"),
    tool.FsPermissionDenied("/physical/a"),
    tool.FsFailure("/physical/a", "reason"),
  ]
  list.each(fs_errors, fn(error) {
    list.each(
      [
        #(w.Write(path("a"), ""), w.WriteCompleted(Error(error))),
        #(w.Initialize, w.InitializationCompleted(Error(error))),
        #(w.Guidance, w.GuidanceCompleted(Error(error))),
        #(
          w.AnchoredEdit(path("a"), plan()),
          w.EditCompleted(Error(fs.LandUnwritten(error))),
        ),
        #(
          w.Read(path("a"), w.Text),
          w.ReadCompleted(Error(w.FileReadFailed(fs.ReadFailed(error)))),
        ),
      ],
      fn(pair) { roundtrip(pair.0, Ok(local.Completed(pair.1, None))) },
    )
  })

  // Search refusal preserves the original path and backend boundary.
  let search_errors = [
    search.InvalidQuery("bad regex"),
    search.NotADirectory("/a"),
    search.NotAFile("/a"),
    search.TooLarge("/a", 999),
    search.NotText("/a"),
    search.Missing("/a"),
    search.Backend(tool.FsFailure("/a", "backend")),
  ]
  list.each(search_errors, fn(error) {
    list.each(
      [
        #(
          w.Read(path("a"), w.Lines(1, 2)),
          w.ReadCompleted(Error(w.LinesReadFailed(error))),
        ),
        #(w.ListEntries(cw.root(), glob()), w.ListingCompleted(Error(error))),
        #(w.Search(cw.root(), grep()), w.SearchCompleted(Error(error))),
        #(w.Stat(path("a")), w.StatCompleted(Error(error))),
      ],
      fn(pair) { roundtrip(pair.0, Ok(local.Completed(pair.1, None))) },
    )
  })
  list.each([fs.NotText, fs.TooLarge(99, 88)], fn(error) {
    roundtrip(
      w.Read(path("a"), w.Text),
      Ok(local.Completed(w.ReadCompleted(Error(w.FileReadFailed(error))), None)),
    )
    roundtrip(
      w.AnchoredEdit(path("a"), plan()),
      Ok(local.Completed(w.EditCompleted(Error(fs.LandUnreadable(error))), None)),
    )
  })
  roundtrip(
    w.Read(path("a"), w.Native(1, 1)),
    Ok(local.Completed(w.ReadCompleted(Error(w.InvalidWindow)), None)),
  )

  // Edit rejection includes enough current evidence to replan.
  let fresh = hashline.annotate("a\n")
  list.each(
    [
      hashline.MalformedPlan("inverted range"),
      hashline.OverlappingHunks(2),
      hashline.StaleAnchors([hashline.Stale(1, hashline.anchor("old"), fresh)]),
      hashline.StaleContent(hashline.digest("a\n"), fresh),
    ],
    fn(error) {
      roundtrip(
        w.AnchoredEdit(path("a"), plan()),
        Ok(local.Completed(
          w.EditCompleted(Error(fs.LandRejected(error, "a\n"))),
          None,
        )),
      )
    },
  )

  // Service refusal stays distinct from an operation-specific failure.
  let service_errors = [
    w.Unavailable,
    w.StaleScope,
    w.PermissionRefused,
    w.InvalidRequest,
    w.CapacityRefused,
    w.IdentityConflict,
    w.OutcomeUnknown,
  ]
  list.each(service_errors, fn(error) { roundtrip(w.Initialize, Error(error)) })
  list.each(
    [
      fs.EmptyPath,
      fs.EscapesWorkspace("/outside"),
      fs.Unresolvable("/a", "reason"),
      fs.ProtectedPath("/a", "/p"),
      fs.ProtectionMisconfigured("/a", "/p"),
    ],
    fn(error) { roundtrip(w.Initialize, Error(w.PathRefused(error))) },
  )
  list.each([w.InvalidObservation, w.CommandFailed(17, "stderr")], fn(error) {
    git_error(error)
  })
  list.each(
    [
      exec.NotReady,
      exec.HandshakeTimeout,
      exec.HelperBusy,
      exec.DegradedHelper(["feature"]),
      exec.DegradedExecution(exec.ExecResult(
        1,
        9,
        123,
        456,
        True,
        False,
        ["skip:net"],
        True,
        99,
        True,
        False,
      )),
      exec.RefusedByHelper("busy", "refused"),
      exec.ChannelFault(
        framing.CorruptFrame(corruption.report(
          "boundary",
          "subject",
          "expected",
          "context",
        )),
      ),
      exec.ChannelFault(framing.VersionMismatch(99)),
      exec.ChannelFault(framing.OversizedFrame(300_000)),
      exec.ChannelClosed(2),
      exec.ProtocolViolation("exec_start"),
      exec.ProtocolVersionMismatch(2, 3),
      exec.SendFailed,
      exec.CancelEscalated,
      exec.HeartbeatMissed,
      exec.HelperUnresponsive,
      exec.ExecutionLost(exec.HelperActorDown),
      exec.ExecutionLost(exec.RelayDown),
      exec.ExecutionLost(exec.ExecutorClosing),
      exec.ExecutionLost(exec.RemoteOutcomeUncertain),
    ],
    fn(error) { git_error(w.ExecutionFailed(error)) },
  )
  list.each(
    [
      broker.PolicyRefused(
        escalation.Denial("denied", escalation.ExecutionDenial(["net"]), [
          policy.GrantWritableRoot("/a"),
          policy.GrantReadableRoot("/b"),
          policy.GrantNetwork(policy.NetworkProxy(
            ["example.org"],
            "http://proxy",
          )),
          policy.GrantNetwork(policy.NetworkOff),
          policy.GrantNetwork(policy.NetworkFull),
          policy.GrantEnv("PATH"),
          policy.GrantLimit(policy.CpuSeconds, 2),
          policy.GrantScratch(policy.ScratchPath("/scratch")),
          policy.GrantScratch(policy.ScratchTmpfs),
        ]),
      ),
      broker.PolicyRefused(
        escalation.Denial("policy", escalation.PolicyDenial, []),
      ),
      broker.BudgetRefused(budget.OutstandingCapReached(7)),
      broker.BudgetRefused(budget.DeadlinePassed(-99)),
      broker.MintRefused(token.EntropyFailure(7)),
      broker.MintRefused(token.DuplicateToken),
      broker.NoHelper(exec.AllBusy(2)),
      broker.NoHelper(exec.PoolUnavailable),
      broker.NoHelper(exec.SpawnFailed(exec.PolicyFileFailed)),
      broker.NoHelper(exec.SpawnFailed(exec.PortOpenFailed)),
      broker.NoHelper(
        exec.SpawnFailed(
          exec.PolicyUnencodable(msgpack.IntegerOutOfRange(
            18_446_744_073_709_551_616,
          )),
        ),
      ),
      broker.NoHelper(
        exec.SpawnFailed(exec.PolicyUnencodable(msgpack.UnencodableLength(99))),
      ),
      broker.NoHelper(exec.SpawnFailed(exec.HandshakeFailed(exec.NotReady))),
      broker.NoHelper(exec.SpawnFailed(exec.ActorFailed(actor.InitTimeout))),
      broker.NoHelper(
        exec.SpawnFailed(exec.ActorFailed(actor.InitFailed("failed"))),
      ),
      broker.NoHelper(
        exec.SpawnFailed(exec.ActorFailed(actor.InitExited(process.Normal))),
      ),
      broker.NoHelper(
        exec.SpawnFailed(exec.ActorFailed(actor.InitExited(process.Killed))),
      ),
      broker.OperationAborted,
      broker.BrokerUnavailable,
    ],
    fn(error) { git_error(w.CommandRefused(error)) },
  )
  list.each(
    [
      policy.CpuSeconds,
      policy.WallSeconds,
      policy.MemBytes,
      policy.Pids,
      policy.FsizeBytes,
      policy.OutputBytes,
    ],
    fn(field) {
      git_error(
        w.CommandRefused(broker.InvalidPolicy(policy.NegativeLimit(field, -2))),
      )
    },
  )
  list.each(
    [
      policy.RelativePath("a"),
      policy.ScratchIsRoot,
      policy.MountOverlapsProtected("/m", "/p"),
      policy.DuplicateMount("/m"),
      policy.MountPathTrailingSlash("/m/"),
      policy.MountPathParentSegment("/m/../x"),
      policy.MountShadowsWritableRoot("/m", "/w"),
    ],
    fn(error) { git_error(w.CommandRefused(broker.InvalidPolicy(error))) },
  )
}

pub fn runtime_terms_are_explicitly_unrepresentable_test() {
  let error =
    w.CommandRefused(
      broker.NoHelper(
        exec.SpawnFailed(
          exec.ActorFailed(
            actor.InitExited(process.Abnormal(dynamic.string("runtime reason"))),
          ),
        ),
      ),
    )
  assert codec.encode_completion(
      w.Git(w.Status),
      Ok(local.Completed(w.GitCompleted(Error(error)), None)),
    )
    == Error(codec.InvalidPayload)
}

pub fn schema_and_identity_mutations_fail_closed_test() {
  let assert Ok(bytes) = codec.encode_invocation(invocation(w.Initialize))
    as "seed invocation"
  let assert Ok(msgpack.ArrayValue(fields)) = msgpack.decode(bytes)
    as "schema array"
  let assert [version, kind, scope, op, step, origin, id, request] = fields
    as "exact envelope"

  // Each mutation keeps the other immutable fields intact.
  let invalid = [
    msgpack.ArrayValue([
      msgpack.IntValue(2),
      kind,
      scope,
      op,
      step,
      origin,
      id,
      request,
    ]),
    msgpack.ArrayValue([
      version,
      msgpack.IntValue(99),
      scope,
      op,
      step,
      origin,
      id,
      request,
    ]),
    msgpack.ArrayValue(list.take(fields, 7)),
    msgpack.ArrayValue(list.append(fields, [msgpack.IntValue(0)])),
    msgpack.ArrayValue([
      version,
      kind,
      scope,
      msgpack.StringValue("bad uuid"),
      step,
      origin,
      id,
      request,
    ]),
    msgpack.ArrayValue([
      version,
      kind,
      scope,
      op,
      step,
      origin,
      msgpack.StringValue("00000000-0000-4000-8000-000000000004"),
      request,
    ]),
    msgpack.ArrayValue([
      version,
      kind,
      scope,
      op,
      msgpack.StringValue(""),
      origin,
      id,
      request,
    ]),
    msgpack.ArrayValue([
      version,
      kind,
      scope,
      op,
      step,
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.ArrayValue([
          msgpack.IntValue(-1),
          msgpack.BinaryValue(<<0:size(256)>>),
        ]),
      ]),
      id,
      request,
    ]),
    msgpack.ArrayValue([
      version,
      kind,
      scope,
      op,
      step,
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.ArrayValue([msgpack.IntValue(0), msgpack.BinaryValue(<<0>>)]),
      ]),
      id,
      request,
    ]),
  ]
  let upper_uuid =
    msgpack.ArrayValue([
      version,
      kind,
      scope,
      msgpack.StringValue("00000000-0000-7000-8000-0000000000AB"),
      step,
      origin,
      id,
      request,
    ])
  let assert Ok(upper_bytes) = msgpack.encode(upper_uuid) as "UUID parser alias"
  assert codec.decode_invocation(upper_bytes) == Error(codec.InvalidPayload)

  list.each(invalid, fn(value) {
    let assert Ok(bad) = msgpack.encode(value) as "mutation encodes"
    assert codec.decode_invocation(bad) == Error(codec.InvalidPayload)
  })

  // Authority coordinates validate independently of payload shape.
  let assert msgpack.ArrayValue([session, executor, checkout, we, se]) = scope
    as "full scope"
  list.each(
    [
      msgpack.ArrayValue([session, executor, checkout, msgpack.IntValue(-1), se]),
      msgpack.ArrayValue([
        session,
        executor,
        checkout,
        we,
        msgpack.IntValue(2_147_483_648),
      ]),
      msgpack.ArrayValue([
        session,
        msgpack.StringValue("bad label/"),
        checkout,
        we,
        se,
      ]),
      msgpack.ArrayValue([
        msgpack.StringValue("bad"),
        executor,
        checkout,
        we,
        se,
      ]),
    ],
    fn(bad_scope) {
      let assert Ok(bad) =
        msgpack.encode(
          msgpack.ArrayValue([
            version,
            kind,
            bad_scope,
            op,
            step,
            origin,
            id,
            request,
          ]),
        )
        as "bad scope encodes"
      assert codec.decode_invocation(bad) == Error(codec.InvalidPayload)
    },
  )
  list.each(["../a", "/a", "a//b", "a\\b", "a:b", "a\u{0000}b"], fn(bad_path) {
    let assert Ok(bad) =
      msgpack.encode(
        msgpack.ArrayValue([
          version,
          kind,
          scope,
          op,
          step,
          origin,
          id,
          msgpack.ArrayValue([
            msgpack.IntValue(5),
            msgpack.StringValue(bad_path),
          ]),
        ]),
      )
      as "bad path encodes"
    assert codec.decode_invocation(bad) == Error(codec.InvalidPayload)
  })

  // Every strict prefix remains incomplete, including a complete header.
  int.range(0, bit_array.byte_size(bytes), Nil, fn(_nil, size) {
    let assert Ok(short) = bit_array.slice(bytes, 0, size) as "prefix exists"
    assert codec.decode_invocation(short) |> result.is_error
    Nil
  })
  assert codec.decode_invocation(<<bytes:bits, 0>>)
    == Error(codec.PreflightRefused)
  assert codec.decode_invocation(<<1:size(1)>>) == Error(codec.PreflightRefused)

  // A semantically equal but wider integer tag cannot produce new evidence bytes.
  let assert <<0x98, 1, rest:bytes>> = bytes as "canonical short version"
  assert codec.decode_invocation(<<0x98, 0xcc, 1, rest:bits>>)
    == Error(codec.InvalidPayload)
}

pub fn kind_domain_inventory_and_numeric_refusals_test() {
  let completed =
    Ok(local.Completed(w.InitializationCompleted(Ok(w.Initialized)), None))
  let assert Ok(bytes) = codec.encode_completion(w.Initialize, completed)
    as "init completion"
  assert codec.decode_completion(w.Guidance, bytes)
    == Error(codec.ResponseMismatch)
  assert codec.encode_completion(w.Guidance, completed)
    == Error(codec.ResponseMismatch)
  let assert Ok(msgpack.ArrayValue([version, tag, result])) =
    msgpack.decode(bytes)
    as "completion envelope"
  list.each(
    [
      msgpack.ArrayValue([msgpack.IntValue(99), tag, result]),
      msgpack.ArrayValue([version, msgpack.IntValue(99), result]),
      msgpack.ArrayValue([version, tag]),
      msgpack.ArrayValue([version, tag, result, result]),
    ],
    fn(bad) {
      let assert Ok(bytes) = msgpack.encode(bad) as "completion mutation"
      assert codec.decode_completion(w.Initialize, bytes)
        == Error(codec.InvalidPayload)
    },
  )

  // Read projections are part of the retained request, not a response guess.
  let text_request = w.Read(path("a"), w.Text)
  let assert Ok(read_bytes) =
    codec.encode_completion(
      text_request,
      Ok(local.Completed(w.ReadCompleted(Ok(w.TextRead("text"))), None)),
    )
    as "text result"
  assert codec.decode_completion(w.Read(path("a"), w.Native(1, 1)), read_bytes)
    == Error(codec.ResponseMismatch)

  // Logical inventory identity cannot be duplicated with altered metadata.
  let entry = search.Entry("a", search.File, 1, 0)
  list.each(
    [
      w.ListingCompleted(
        Ok(search.Listing(
          [entry, search.Entry(..entry, size: 2)],
          search.Complete,
        )),
      ),
      w.ListingCompleted(
        Ok(search.Listing([search.Entry(..entry, size: -1)], search.Complete)),
      ),
    ],
    fn(reply) {
      assert codec.encode_completion(
          w.ListEntries(cw.root(), glob()),
          Ok(local.Completed(reply, None)),
        )
        == Error(codec.InvalidPayload)
    },
  )
  assert codec.encode_invocation(
      invocation(w.ListEntries(
        cw.root(),
        search.GlobQuery("*", 4097, search.SkipHidden, []),
      )),
    )
    == Error(codec.InvalidPayload)
  assert codec.encode_invocation(
      invocation(w.Search(
        cw.root(),
        search.GrepQuery("[", [], 0, 1, search.SkipHidden, []),
      )),
    )
    == Error(codec.InvalidPayload)
  assert codec.encode_invocation(
      invocation(w.ListEntries(
        cw.root(),
        search.GlobQuery("*", 1, search.SkipHidden, ["same", "same"]),
      )),
    )
    == Error(codec.InvalidPayload)
  assert codec.encode_invocation(
      invocation(w.Read(path("a"), w.Lines(1, 2001))),
    )
    == Error(codec.InvalidPayload)
  assert codec.encode_invocation(invocation(w.Read(path("a"), w.Native(0, 1))))
    == Error(codec.InvalidPayload)

  // Image signatures and byte alignment are checked alongside the declared media.
  assert codec.encode_completion(
      w.Read(path("a"), w.Native(1, 1)),
      Ok(local.Completed(
        w.ReadCompleted(Ok(w.ImageRead(<<"GIF89a">>, w.Png))),
        None,
      )),
    )
    == Error(codec.InvalidPayload)
  assert codec.encode_completion(
      w.Read(path("a"), w.Native(1, 1)),
      Ok(local.Completed(
        w.ReadCompleted(Ok(w.ImageRead(<<1:size(1)>>, w.Png))),
        None,
      )),
    )
    == Error(codec.InvalidPayload)
  assert codec.encode_completion(
      w.Write(path("a"), "x"),
      Ok(local.Completed(
        w.WriteCompleted(
          Ok(w.Written(2, hashline.digest("x"), w.RequiresWindowedRead)),
        ),
        None,
      )),
    )
    == Error(codec.InvalidPayload)
}

pub fn semantic_byte_limits_and_large_postimage_are_explicit_test() {
  assert codec.max_invocation_bytes == 9_437_184
  assert codec.max_completion_bytes == 33_554_432

  // Eight-MiB host material requires chunking and still fits semantic admission.
  let max_content = string.repeat("x", 8_388_608)
  let call = invocation(w.Write(path("a"), max_content))
  let assert Ok(bytes) = codec.encode_invocation(call)
    as "eight MiB writes remain representable"
  assert bit_array.byte_size(bytes) > 262_144
  assert codec.decode_invocation(bytes) == Ok(call)
  assert codec.encode_invocation(
      invocation(w.Write(path("a"), max_content <> "x")),
    )
    == Error(codec.InvalidPayload)

  // Total wire bytes are bounded before even the first msgpack header is read.
  assert codec.decode_invocation(<<0:unit(8)-size(9_437_185)>>)
    == Error(codec.PayloadTooLarge)
  assert codec.decode_completion(w.Initialize, <<0:unit(8)-size(33_554_433)>>)
    == Error(codec.PayloadTooLarge)
  roundtrip(
    w.AnchoredEdit(path("a"), plan()),
    Ok(local.Completed(
      w.EditCompleted(Ok(fs.Landed("a", string.repeat("z", 9_000_000)))),
      None,
    )),
  )

  // Independent byte admission rejects aggregate observations without truncation.
  let files = [
    w.GuidanceFile(path("a"), max_content),
    w.GuidanceFile(path("b"), max_content),
    w.GuidanceFile(path("c"), max_content),
    w.GuidanceFile(path("d"), max_content),
  ]
  assert codec.encode_completion(
      w.Guidance,
      Ok(local.Completed(
        w.GuidanceCompleted(Ok(w.GuidanceLoaded(files, search.Complete))),
        None,
      )),
    )
    == Error(codec.PayloadTooLarge)
  assert codec.encode_completion(
      w.Initialize,
      Ok(local.Completed(
        w.InitializationCompleted(Ok(w.Initialized)),
        Some(string.repeat("d", value.max_diagnostic_bytes + 1)),
      )),
    )
    == Error(codec.InvalidPayload)
}

pub fn allocation_preflight_exact_limits_and_claimed_lengths_test() {
  assert preflight.scan(nested(32)) == Ok(Nil)
  assert preflight.scan(nested(33)) == Error(Nil)

  // Element count and aggregate nodes are independent limits.
  let zeros = <<0:unit(8)-size(8192)>>
  assert preflight.scan(<<0xdc, 8192:size(16), zeros:bits>>) == Ok(Nil)
  assert preflight.scan(<<0xdc, 8193:size(16), zeros:bits, 0>>) == Error(Nil)

  // Eight legal containers can exhaust the aggregate node budget.
  let bucket = <<0xdc, 8191:size(16), 0:unit(8)-size(8191)>>
  assert preflight.scan(bit_array.concat([<<0x98>>, ..list.repeat(bucket, 8)]))
    == Error(Nil)
  let short_bucket = <<0xdc, 8190:size(16), 0:unit(8)-size(8190)>>
  assert preflight.scan(
      bit_array.concat([<<0x98>>, short_bucket, ..list.repeat(bucket, 7)]),
    )
    == Ok(Nil)
  list.each(
    [
      <<0xdd, 25_000_000:size(32)>>,
      <<0xdc, 8192:size(16), 0>>,
      <<0xdb, 0xffffffff:size(32)>>,
      <<0xc6, 0xffffffff:size(32)>>,
      <<0xc4, 9, 1, 2>>,
      <<0x81, 1, 2>>,
      <<0xc7, 0, 0>>,
      <<0xcb, 0:size(64)>>,
    ],
    fn(bad) {
      assert preflight.scan(bad) == Error(Nil)
    },
  )
}

pub fn actual_local_file_results_survive_codec_without_projection_loss_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "test working directory"
  let root = here <> "/build/workspace_codec_test/real"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "fixture directory"
  let ctx =
    fake_broker.ctx(root, fs.real_filesystem(), 1000, [], process.new_subject())
  let host =
    local.new(scope(), ctx, fn(_) { Some("settled post-write diagnostics") })

  // The retained request selects the completion projection.
  let requests = [
    w.Write(path("a"), "a\nb\n"),
    w.Read(path("a"), w.Text),
    w.Read(path("a"), w.Native(2, 1)),
    w.Read(path("a"), w.Lines(2, 99)),
    w.AnchoredEdit(path("a"), plan()),
    w.AnchoredEdit(path("a"), plan()),
    w.ListEntries(cw.root(), glob()),
    w.Search(cw.root(), grep()),
    w.Stat(path("a")),
    w.Read(path("absent"), w.Text),
    w.Guidance,
    w.Initialize,
  ]
  list.each(requests, fn(request) {
    let output = local.run(host, invocation(request))
    roundtrip(request, output)
  })
  assert simplifile.read(root <> "/a") == Ok("A\nb\n")
}

fn nested(depth: Int) -> BitArray {
  case depth {
    0 -> <<0>>
    _ -> <<0x91, nested(depth - 1):bits>>
  }
}

fn git_error(error: w.GitError) {
  roundtrip(
    w.Git(w.Status),
    Ok(local.Completed(w.GitCompleted(Error(error)), None)),
  )
}

fn roundtrip(
  expected: w.Request,
  output: Result(local.Completed, w.ServiceError),
) {
  let assert Ok(bytes) = codec.encode_completion(expected, output)
    as "completion is representable"
  assert codec.decode_completion(expected, bytes) == Ok(output)
  let assert Ok(decoded) = codec.decode_completion(expected, bytes)
    as "completion decodes"
  assert codec.encode_completion(expected, decoded) == Ok(bytes)
}

fn scope() -> cw.Scope {
  let assert Ok(scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "executor",
      "checkout",
      23,
      19,
    )
    as "full scope"
  scope
}

fn invocation(request: w.Request) -> w.Invocation {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "physical op"
  let assert Ok(step) = cw.step("build:physical:7") as "physical step"
  let assert Ok(id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000003")
    as "reserved request UUID"
  let assert Ok(origin) = w.tool_origin(37, <<0xab:unit(8)-size(32)>>)
    as "original index and argument digest"
  w.invocation(scope(), op, step, w.Tool(origin), id, request)
}

fn path(text: String) -> cw.RelativePath {
  let assert Ok(path) = cw.relative_path(text) as "canonical fixture path"
  path
}

fn revision() -> w.Revision {
  let assert Ok(revision) = w.revision(string.repeat("a", 40))
    as "full revision"
  revision
}

fn plan() -> hashline.Plan {
  let ref = hashline.Ref(1, hashline.anchor("a"))
  hashline.Plan(hashline.digest("a\nb\n"), [hashline.Replace(ref, ref, ["A"])])
}

fn glob() -> search.GlobQuery {
  search.GlobQuery("**", 9, search.IncludeHidden, [".git"])
}

fn grep() -> search.GrepQuery {
  search.GrepQuery("needle", ["*.txt"], 1, 9, search.SkipHidden, [])
}

pub fn nested_tags_arities_enums_and_revision_fail_binary_decode_test() {
  let malformed = [
    msgpack.ArrayValue([msgpack.IntValue(99)]),
    msgpack.ArrayValue([msgpack.IntValue(5)]),
    msgpack.ArrayValue([
      msgpack.IntValue(5),
      msgpack.StringValue("a"),
      msgpack.IntValue(0),
    ]),
    msgpack.ArrayValue([
      msgpack.IntValue(0),
      msgpack.StringValue("a"),
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        msgpack.IntValue(-1),
        msgpack.IntValue(1),
      ]),
    ]),
    msgpack.ArrayValue([
      msgpack.IntValue(3),
      msgpack.StringValue("."),
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.StringValue("*"),
        msgpack.IntValue(1),
        msgpack.ArrayValue([msgpack.IntValue(99)]),
        msgpack.ArrayValue([]),
      ]),
    ]),
    msgpack.ArrayValue([
      msgpack.IntValue(6),
      msgpack.ArrayValue([
        msgpack.IntValue(3),
        msgpack.ArrayValue([
          msgpack.IntValue(2),
          msgpack.StringValue("--output=/secret"),
        ]),
      ]),
    ]),
    msgpack.ArrayValue([
      msgpack.IntValue(6),
      msgpack.ArrayValue([msgpack.IntValue(4), msgpack.IntValue(1001)]),
    ]),
  ]
  let assert Ok(bytes) = codec.encode_invocation(invocation(w.Initialize))
    as "mutation seed"
  let assert Ok(msgpack.ArrayValue(fields)) = msgpack.decode(bytes)
    as "invocation array"
  list.each(malformed, fn(payload) {
    let assert Ok(bad) =
      msgpack.encode(
        msgpack.ArrayValue(list.append(list.take(fields, 7), [payload])),
      )
      as "closed malformed request"
    assert codec.decode_invocation(bad) == Error(codec.InvalidPayload)
  })
  let completion =
    Ok(local.Completed(w.InitializationCompleted(Ok(w.Initialized)), None))
  let assert Ok(bytes) = codec.encode_completion(w.Initialize, completion)
    as "completion seed"
  let assert Ok(msgpack.ArrayValue([version, tag, _])) = msgpack.decode(bytes)
    as "completion envelope"
  list.each(
    [
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.ArrayValue([msgpack.IntValue(99)]),
        msgpack.ArrayValue([msgpack.IntValue(0)]),
      ]),
      msgpack.ArrayValue([
        msgpack.IntValue(0),
        msgpack.ArrayValue([
          msgpack.IntValue(8),
          msgpack.ArrayValue([
            msgpack.IntValue(0),
            msgpack.ArrayValue([msgpack.IntValue(99)]),
          ]),
        ]),
        msgpack.ArrayValue([msgpack.IntValue(0)]),
      ]),
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        msgpack.ArrayValue([msgpack.IntValue(99)]),
      ]),
    ],
    fn(payload) {
      let assert Ok(bad) =
        msgpack.encode(msgpack.ArrayValue([version, tag, payload]))
        as "unknown result tags"
      assert codec.decode_completion(w.Initialize, bad)
        == Error(codec.InvalidPayload)
    },
  )
}

pub fn total_invocation_encode_budget_is_independent_of_domain_caps_test() {
  // Each pattern and prune component fits; their aggregate exceeds nine MiB.
  let globs =
    int.range(0, 8192, [], fn(xs, i) {
      [string.repeat("g", 1018) <> int.to_string(i), ..xs]
    })
  let prune =
    int.range(0, 8192, [], fn(xs, i) {
      [string.repeat("p", 252) <> int.to_string(i), ..xs]
    })
  let call =
    invocation(w.Search(
      cw.root(),
      search.GrepQuery("needle", globs, 0, 1, search.SkipHidden, prune),
    ))
  assert codec.encode_invocation(call) == Error(codec.PayloadTooLarge)
}

pub fn maximal_landed_edit_plus_max_diagnostics_fits_reserved_completion_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "test working directory"
  let root = here <> "/build/workspace_codec_test/maximal"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "maximal fixture"
  let before = string.repeat("x", local.max_request_bytes)

  // The original file and insertion consume their actual host byte allowances.
  let digest = hashline.digest(before)
  let inserted =
    string.repeat("y", local.max_request_bytes - string.byte_size(digest) - 1)
  let plan = hashline.Plan(digest, [hashline.InsertAtStart([inserted])])
  let assert Ok(Nil) = simplifile.write(root <> "/a", before)
    as "eight MiB preimage"
  let ctx =
    fake_broker.ctx(root, fs.real_filesystem(), 1000, [], process.new_subject())
  let diagnostics = string.repeat("d", value.max_diagnostic_bytes)
  let host = local.new(scope(), ctx, fn(_) { Some(diagnostics) })

  // Completion evidence comes from the host after one real mutation.
  let request = w.AnchoredEdit(path("a"), plan)
  let output = local.run(host, invocation(request))
  let assert Ok(local.Completed(w.EditCompleted(Ok(landed)), observed)) = output
    as "maximal edit really lands"
  assert landed.before == before
  assert landed.edited == inserted <> "\n" <> before
  assert observed == Some(diagnostics)
  assert simplifile.read(root <> "/a") == Ok(landed.edited)

  // The reservation includes the envelope and maximal observer diagnostics.
  let assert Ok(bytes) = codec.encode_completion(request, output)
    as "successful mutation fits its reservation"
  assert bit_array.byte_size(bytes) == 25_231_364
  assert bit_array.byte_size(bytes) > 25_165_824
  assert bit_array.byte_size(bytes) < codec.max_completion_bytes
  assert codec.decode_completion(request, bytes) == Ok(output)
}

pub fn full_legal_symlink_inventory_fits_aggregate_node_budget_test() {
  // Every existing glob entry can be a symlink; reserve its eight nodes and
  // the completion envelope before claiming full listing interoperability.
  let entries =
    int.range(0, search.max_entries_ceiling, [], fn(xs, i) {
      [search.Entry("e" <> int.to_string(i), search.Symlink("t"), 1, 0), ..xs]
    })
    |> list.reverse
  let reply = w.ListingCompleted(Ok(search.Listing(entries, search.Complete)))
  let request =
    w.ListEntries(
      cw.root(),
      search.GlobQuery("**", search.max_entries_ceiling, search.IncludeHidden, [
        ".git",
      ]),
    )
  let completed = Ok(local.Completed(reply, None))
  let assert Ok(bytes) = codec.encode_completion(request, completed)
    as "full symlink inventory fits"
  assert bit_array.byte_size(bytes) == 56_252
  assert codec.decode_completion(request, bytes) == Ok(completed)
  assert preflight.max_nodes == 65_536
}

pub fn native_short_line_window_above_line_reader_limit_roundtrips_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "test working directory"
  let root = here <> "/build/workspace_codec_test/native_short_lines"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "native window fixture"
  let content = string.repeat("\n", 2001)
  let assert Ok(Nil) = simplifile.write(root <> "/a", content)
    as "2001 empty lines on disk"
  let ctx =
    fake_broker.ctx(root, fs.real_filesystem(), 1000, [], process.new_subject())
  let host = local.new(scope(), ctx, fn(_) { None })
  let request = w.Read(path("a"), w.Native(1, 2001))
  let call = invocation(request)
  let assert Ok(bytes) = codec.encode_invocation(call)
    as "native span is admitted"
  assert codec.decode_invocation(bytes) == Ok(call)

  // Native output is bounded by rendered bytes rather than Lines' span limit.
  let output = local.run(host, call)
  let assert Ok(local.Completed(
    w.ReadCompleted(Ok(w.AnchoredRead(digest, window))),
    None,
  )) = output
    as "native host returns all requested anchors"
  assert digest == hashline.digest(content)
  assert window == hashline.window(content, 1, 2001)
  assert list.length(window.lines) == 2001
  roundtrip(request, output)
  assert codec.encode_invocation(
      invocation(w.Read(path("a"), w.Lines(1, 2001))),
    )
    == Error(codec.InvalidPayload)
}

pub fn real_host_file_start_overlap_roundtrips_zero_coordinate_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "test working directory"
  let root = here <> "/build/workspace_codec_test/edit_refusals"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "edit refusal fixture"
  let assert Ok(Nil) = simplifile.write(root <> "/a", "a\n")
    as "overlap preimage"
  let ctx =
    fake_broker.ctx(root, fs.real_filesystem(), 1000, [], process.new_subject())
  let host = local.new(scope(), ctx, fn(_) { None })
  let request =
    w.AnchoredEdit(
      path("a"),
      hashline.Plan(hashline.digest("a\n"), [
        hashline.InsertAtStart(["x"]),
        hashline.InsertAtStart(["y"]),
      ]),
    )
  let call = invocation(request)
  let assert Ok(bytes) = codec.encode_invocation(call)
    as "overlapping plan is admitted for host validation"
  assert codec.decode_invocation(bytes) == Ok(call)

  // Two file-start insertions overlap at coordinate zero and never write.
  let output = local.run(host, call)
  assert output
    == Ok(local.Completed(
      w.EditCompleted(
        Error(fs.LandRejected(hashline.OverlappingHunks(0), "a\n")),
      ),
      None,
    ))
  roundtrip(request, output)
  assert simplifile.read(root <> "/a") == Ok("a\n")
}

pub fn real_host_repeated_stale_anchors_retain_order_and_duplicates_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "test working directory"
  let root = here <> "/build/workspace_codec_test/repeated_stale_anchors"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "repeated stale anchor fixture"
  let ctx =
    fake_broker.ctx(root, fs.real_filesystem(), 1000, [], process.new_subject())
  let host = local.new(scope(), ctx, fn(_) { None })

  // Every hunk contributes its stale reference before overlap validation runs.
  let assert Ok(Nil) = simplifile.write(root <> "/a", "new\n")
    as "concurrently changed preimage"
  let ref = hashline.Ref(1, hashline.anchor("old"))
  let request =
    w.AnchoredEdit(
      path("a"),
      hashline.Plan(hashline.digest("old\n"), [
        hashline.InsertAfter(ref, ["x"]),
        hashline.InsertAfter(ref, ["y"]),
      ]),
    )
  let call = invocation(request)
  let assert Ok(bytes) = codec.encode_invocation(call)
    as "repeated references are admitted"
  assert codec.decode_invocation(bytes) == Ok(call)
  let output = local.run(host, call)
  let stale = hashline.Stale(1, ref.anchor, hashline.annotate("new\n"))
  assert output
    == Ok(local.Completed(
      w.EditCompleted(
        Error(fs.LandRejected(hashline.StaleAnchors([stale, stale]), "new\n")),
      ),
      None,
    ))
  roundtrip(request, output)
  assert simplifile.read(root <> "/a") == Ok("new\n")
}

pub fn real_host_stale_content_retains_5000_fresh_lines_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "test working directory"
  let root = here <> "/build/workspace_codec_test/stale_content"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "stale content fixture"
  let before = string.repeat("a\n", 5000)
  let current =
    string.repeat("a\n", 2499) <> "b\n" <> string.repeat("a\n", 2500)
  let assert Ok(Nil) = simplifile.write(root <> "/a", current)
    as "interior line changed while endpoint anchors remain current"
  let request =
    w.AnchoredEdit(
      path("a"),
      hashline.Plan(hashline.digest(before), [
        hashline.Delete(
          hashline.Ref(1, hashline.anchor("a")),
          hashline.Ref(5000, hashline.anchor("a")),
        ),
      ]),
    )
  let call = invocation(request)
  let assert Ok(bytes) = codec.encode_invocation(call)
    as "large touched range needs only two request references"
  assert codec.decode_invocation(bytes) == Ok(call)
  let ctx =
    fake_broker.ctx(root, fs.real_filesystem(), 1000, [], process.new_subject())
  let host = local.new(scope(), ctx, fn(_) { None })

  // StaleContent returns the full touched range, independently of listing caps.
  let output = local.run(host, call)
  assert output
    == Ok(local.Completed(
      w.EditCompleted(
        Error(fs.LandRejected(
          hashline.StaleContent(
            hashline.digest(current),
            hashline.annotate(current),
          ),
          current,
        )),
      ),
      None,
    ))
  roundtrip(request, output)
  assert simplifile.read(root <> "/a") == Ok(current)
}

pub fn real_host_unix_colon_filename_listing_and_search_roundtrip_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "test working directory"
  let root = here <> "/build/workspace_codec_test/observed_names"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "Unix observed name fixture"
  let assert Ok(Nil) = simplifile.write(root <> "/a:b", "needle\n")
    as "Unix permits colon in observed filenames"
  let ctx =
    fake_broker.ctx(root, fs.real_filesystem(), 1000, [], process.new_subject())
  let host = local.new(scope(), ctx, fn(_) { None })
  let request =
    w.ListEntries(
      cw.root(),
      search.GlobQuery("*", 10, search.IncludeHidden, []),
    )
  let call = invocation(request)
  let assert Ok(bytes) = codec.encode_invocation(call)
    as "listing retains a strict root authority path"
  assert codec.decode_invocation(bytes) == Ok(call)

  // Observed names are data, including names a later request cannot authorize.
  let output = local.run(host, call)
  let assert Ok(local.Completed(
    w.ListingCompleted(Ok(search.Listing([entry], search.Complete))),
    None,
  )) = output
    as "real walker lists the colon filename"
  assert entry.path == "a:b"
  assert entry.kind == search.File
  assert entry.size == 7
  roundtrip(request, output)
  let request =
    w.Search(
      cw.root(),
      search.GrepQuery("needle", [], 0, 10, search.IncludeHidden, []),
    )
  let call = invocation(request)
  let assert Ok(bytes) = codec.encode_invocation(call)
    as "search retains a strict root authority path"
  assert codec.decode_invocation(bytes) == Ok(call)
  let output = local.run(host, call)
  let assert Ok(local.Completed(
    w.SearchCompleted(Ok(search.Found([matched], _, _, search.Exhaustive))),
    None,
  )) = output
    as "real grep matches the colon filename"
  assert matched.path == "a:b"
  assert matched.text == "needle"
  roundtrip(request, output)

  // Request paths and prune components retain their existing strict grammar.
  assert cw.relative_path("a:b") == Error(cw.PathSeparator)
  assert codec.encode_invocation(
      invocation(w.ListEntries(
        cw.root(),
        search.GlobQuery("*", 10, search.IncludeHidden, ["a:b"]),
      )),
    )
    == Error(codec.InvalidPayload)
}
