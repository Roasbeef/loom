pub fn greet(name: String) -> String {
  "Hello, " <> name
}

pub fn twice(name: String) -> String {
  greet(name) <> greet(name)
}
