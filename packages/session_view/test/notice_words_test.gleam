//// The words of a command's outcome are a closed table: no wire name, no
//// underscore and no status verb ever reaches a footer.

import gleam/list
import gleam/string
import session_view/notice_words

// Every command the page or the terminal can issue, with the status the
// daemon answers it with. None of the words may be the event's name.
const commands = [
  "prompt", "prompt_content", "steer", "follow_up", "goal_get", "goal_set",
  "goal_check", "goal_clear", "goal_pause", "goal_resume", "fork", "deny",
  "approve", "abort", "compact", "create_strand", "set_config",
  "schedule_cancel", "edit_queued_input", "notes", "something_new",
]

pub fn a_goal_command_is_worded_as_what_it_did_test() {
  assert notice_words.outcome("goal_set", "admitted") == "Goal pinned"
  assert notice_words.outcome("goal_clear", "admitted") == "Goal cleared"
  assert notice_words.outcome("goal_pause", "admitted") == "Goal paused"
  assert notice_words.outcome("goal_resume", "admitted") == "Goal resumed"
}

pub fn a_decision_and_a_fork_are_worded_plainly_test() {
  assert notice_words.outcome("deny", "committed") == "Denied"
  assert notice_words.outcome("approve", "committed") == "Allowed once"
  assert notice_words.outcome("fork", "committed") == "Forked"
}

pub fn a_prompt_the_daemon_booked_says_so_test() {
  assert notice_words.outcome("prompt", "admitted") == "Sent"
  assert notice_words.outcome("prompt", "queued") == "Queued for the next turn"
}

pub fn a_command_the_table_does_not_list_is_still_words_test() {
  assert notice_words.sent("something_new") == "Sending"
  assert notice_words.outcome("something_new", "admitted") == "Done"
  assert notice_words.outcome("something_new", "queued") == "Queued"
}

pub fn no_notice_is_a_wire_name_test() {
  list.each(commands, fn(command) {
    list.each(["admitted", "committed", "queued"], fn(status) {
      let said = [
        notice_words.sent(command),
        notice_words.outcome(command, status),
      ]
      list.each(said, fn(words) {
        assert !string.contains(words, "_") as words
        assert !string.contains(words, " committed") as words
        assert !string.contains(words, " admitted") as words
        assert words != command as words
      })
    })
  })
}
