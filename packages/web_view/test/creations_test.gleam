//// The pure half of the rule for a typed folder (protocol-change/074): the
//// text it may hold, how a leading `~` is read and where a canonical folder may
//// lie. The daemon applies the filesystem half (`client/daemon/new_folder`).

import gleam/string
import web_view/creations

// The pure half of the rule for a typed path.
pub fn a_typed_path_is_clean_expanded_and_inside_home_test() {
  assert creations.typed_path("  ~/code/app ") == Ok("~/code/app")
  assert creations.typed_path("") == Error(Nil)
  assert creations.typed_path("   ") == Error(Nil)
  assert creations.typed_path("/a\nb") == Error(Nil)
  assert creations.typed_path("/a\u{202e}b") == Error(Nil)
  assert creations.typed_path(string.repeat("a", 4097)) == Error(Nil)
  assert creations.typed_path("/" <> string.repeat("a", 4095))
    == Ok("/" <> string.repeat("a", 4095))

  assert creations.expanded("~", "/home/o") == Ok("/home/o")
  assert creations.expanded("~/code", "/home/o") == Ok("/home/o/code")
  assert creations.expanded("/srv/app", "/home/o") == Ok("/srv/app")
  assert creations.expanded("code", "/home/o") == Error(Nil)
  assert creations.expanded("./code", "/home/o") == Error(Nil)
  assert creations.expanded("~root/x", "/home/o") == Error(Nil)

  assert creations.inside("/home/o", "/home/o/code/app") == Ok(Nil)
  assert creations.inside("/home/o", "/home/o") == Error(creations.OutsideHome)
  assert creations.inside("/home/o", "/home/other/app")
    == Error(creations.OutsideHome)
  assert creations.inside("/home/o", "/home/o2") == Error(creations.OutsideHome)
  assert creations.inside("/home/o", "/etc") == Error(creations.OutsideHome)
  assert creations.inside("/home/o", "/home/o/.ssh")
    == Error(creations.OutsideHome)
  assert creations.inside("/home/o", "/home/o/code/.git/x")
    == Error(creations.OutsideHome)
  assert creations.inside("/home/o", "/home/o/a.b/c") == Ok(Nil)
  assert creations.inside("/home/o", "/home/o/Library")
    == Error(creations.OutsideHome)
  assert creations.inside("/home/o", "/home/o/library/Keychains")
    == Error(creations.OutsideHome)
  assert creations.inside("/home/o", "/home/o/code/Library") == Ok(Nil)
}
