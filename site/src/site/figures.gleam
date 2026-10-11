//// The figures the site shows, looked up by id.

import lustre/element.{type Element}
import site/fig_approval
import site/fig_codemode
import site/fig_crash
import site/fig_migration
import site/figure.{type Spec}
import site/msg.{type FigureId, type Msg}

/// Every figure, in the order of the landing page.
pub fn all() -> List(FigureId) {
  [msg.Crash, msg.Approval, msg.CodeMode, msg.Migration]
}

/// The text of a figure.
pub fn spec(id: FigureId) -> Spec {
  case id {
    msg.Crash -> fig_crash.spec()
    msg.Approval -> fig_approval.spec()
    msg.CodeMode -> fig_codemode.spec()
    msg.Migration -> fig_migration.spec()
  }
}

/// The drawing of a figure at a step.
pub fn drawing(id: FigureId, step: Int) -> Element(Msg) {
  case id {
    msg.Crash -> fig_crash.drawing(step)
    msg.Approval -> fig_approval.drawing(step)
    msg.CodeMode -> fig_codemode.drawing(step)
    msg.Migration -> fig_migration.drawing(step)
  }
}
