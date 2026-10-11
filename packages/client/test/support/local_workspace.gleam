//// The handles only a session with a local workspace has.
////
//// An `Instance` holds its helper pool and executor service as options,
//// because a session whose workspace is registered on an executor has neither.
//// Most fixtures assemble local sessions and want the handle itself.

import broker/exec.{type Pool}
import broker/executor
import client/serve
import gleam/option.{Some}

/// The helper pool of a session whose workspace is local.
pub fn pool(instance: serve.Instance) -> Pool {
  let assert Some(pool) = instance.pool as "the session has a local workspace"
  pool
}

/// The executor service of a session whose workspace is local.
pub fn executor(instance: serve.Instance) -> executor.Executor {
  let assert Some(service) = instance.executor
    as "the session has a local workspace"
  service
}
