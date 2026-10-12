//// The search indexer cannot import `session_view` or `client`, so it mirrors
//// the leads and fences of the memory injections as its own constants and
//// skips a user message that matches. This pins each mirror equal to the
//// constant the composer and `client/memory` use, so rewording an injection
//// cannot silently put it back in the index. The digest injection was
//// removed, but sessions saved while it existed still hold it, so its mirror
//// stays pinned against the composer.

import client/memory
import events/search
import session_view/composer

pub fn the_indexer_mirrors_the_removed_digest_injection_test() {
  assert search.digest_attribution_lead == composer.memory_attribution_lead
  assert search.digest_fence == composer.memory_fence
}

pub fn the_indexer_mirrors_the_notes_injection_test() {
  assert search.notes_attribution_lead == composer.notes_attribution_lead
  assert search.notes_fence == composer.notes_fence
  assert search.notes_fence == memory.notes_fence
}
