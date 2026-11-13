// The directory of a spawner's feeds, which counts places
// (protocol-change/108, "The box's feed host"; `client/remote/feed_directory`).
//
// A feed asks for a place when it attaches and is refused at the cap. A feed
// holds its place from then until its process exits. An ended feed is still a
// process, with its connection permit, until it is forgotten one lease after it
// ended, so it still holds its place, and a feed says it is gone only then, or
// when the page detaches and the process exits at once.
machine Directory {
  var used: int;

  start state Running {
    on eReserve do (feed: machine) {
      if (used >= Cap()) {
        send feed, eCapRefused;
      } else {
        used = used + 1;
        send feed, eReserved;
      }
    }

    on eFeedGone do {
      used = used - 1;
    }
  }
}
