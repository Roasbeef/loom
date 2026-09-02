//// Outbound HTTP externals for the broker's egress surface.
////
//// FFI confinement (spec §0.2): `broker/egress` decides — scheme, host,
//// method, headers, secrets, redirects — and this module is the only
//// place the decision touches a socket. One external performs exactly
//// one hop and answers with a value; the redirect chain, the secret
//// injection and the whole-request deadline stay in Gleam, where they
//// are readable and testable.
////
//// The shims behind these externals live in `broker_ffi.erl`. They own
//// the private `httpc` profile, the TLS options, and the streamed body
//// accumulation that aborts a response the moment it passes its cap;
//// none of those have a pure alternative on the BEAM.

/// Which certificate authorities a hop is allowed to chain to.
///
/// The mirror of `egress.Trust` on the FFI boundary. It is declared here
/// rather than imported so that `broker/egress` can own the public type
/// without this module importing its importer.
pub type Roots {
  /// The platform's own trust store, via `public_key:cacerts_get/0`.
  SystemTrust

  /// Exactly these DER-encoded certificates and nothing else. An empty
  /// list is a valid, permanently failing pin: nothing verifies.
  PinnedTrust(ders: List(BitArray))
}

/// What one hop produced. Every variant is terminal: the Erlang side
/// has already cancelled the request and drained its own mailbox before
/// answering, so no `httpc` message outlives the call.
pub type FetchOutcome {
  /// A complete response. Header names are already lowercased and both
  /// names and values are valid UTF-8.
  Fetched(status: Int, headers: List(#(String, String)), body: BitArray)

  /// The response declared or delivered more than `cap` bytes of body,
  /// and the request was cancelled rather than drained.
  FetchTooLarge(cap: Int)

  /// The hop's share of the caller's deadline ran out.
  FetchTimedOut

  /// Connect, TLS or protocol failure. `reason` is a rendering of the
  /// transport's own error term, truncated; it never carries a request
  /// header, so a secret cannot reach it.
  FetchFailed(reason: String)
}

/// Performs one HTTPS hop under the given caps and returns its outcome.
///
/// `method` is the lowercase method name (`"get"`, `"post"`, …);
/// `timeout_ms` is what remains of the caller's whole-request deadline,
/// not a fresh budget. Redirects are never followed here: a 3xx comes
/// back as an ordinary `Fetched` for `broker/egress` to judge.
///
/// Uses OTP `httpc` on a broker-private profile with `autoredirect`
/// off and the body streamed, so the size cap is enforced while bytes
/// arrive instead of after they have all been buffered.
@external(erlang, "broker_ffi", "egress_fetch")
pub fn fetch(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
  max_response_bytes: Int,
  timeout_ms: Int,
  roots: Roots,
) -> FetchOutcome

/// Milliseconds on the BEAM's monotonic clock.
///
/// The whole-request deadline is measured against this rather than
/// wall time, so a clock step during a slow transfer cannot lengthen or
/// shorten what the caller asked for. There is no pure alternative.
@external(erlang, "broker_ffi", "egress_monotonic_ms")
pub fn monotonic_ms() -> Int
