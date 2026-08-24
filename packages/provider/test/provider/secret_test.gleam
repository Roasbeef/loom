import provider/secret

pub fn from_list_lookup_test() {
  let store = secret.from_list([#("KEY", "value")])
  assert secret.lookup(store, "KEY") == Ok("value")
  assert secret.lookup(store, "OTHER") == Error(Nil)
}

pub fn from_function_lookup_test() {
  let store =
    secret.from_function(fn(name) {
      case name {
        "ONLY" -> Ok("v")
        _ -> Error(Nil)
      }
    })
  assert secret.lookup(store, "ONLY") == Ok("v")
  assert secret.lookup(store, "ELSE") == Error(Nil)
}

pub fn env_backend_reads_the_process_environment_test() {
  let store = secret.env()
  // PATH is set in any test environment; a random name is not.
  let assert Ok(_path) = secret.lookup(store, "PATH")
  assert secret.lookup(store, "LOOM_PROVIDER_UNSET_VARIABLE_9Z") == Error(Nil)
}
