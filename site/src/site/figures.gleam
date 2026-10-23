//// The figures the site shows, looked up by id.

import site/fig_approval
import site/fig_codemode
import site/fig_crash
import site/fig_evolution
import site/fig_migration
import site/figure.{type Spec}
import site/msg.{type FigureId}

/// Every figure, in the order of the landing page, then the figures that only
/// a documentation page embeds.
pub fn all() -> List(FigureId) {
  [msg.Crash, msg.Approval, msg.CodeMode, msg.Migration, msg.Evolution]
}

/// The text of a figure.
pub fn spec(id: FigureId) -> Spec {
  case id {
    msg.Crash -> fig_crash.spec()
    msg.Approval -> fig_approval.spec()
    msg.CodeMode -> fig_codemode.spec()
    msg.Migration -> fig_migration.spec()
    msg.Evolution -> fig_evolution.spec()
  }
}
