package libkrun

import (
	"math/rand"
	"testing"
	"testing/quick"
)

// TestNofileSoftProperty checks the rule for every hard limit: a limit below
// minNofile is refused, and any other is used whole as the soft limit, so the
// runner never starts below what the hard limit allows. The seed is fixed so
// that a failure reproduces.
func TestNofileSoftProperty(t *testing.T) {
	// The hard limit is drawn from twice the floor, so that about half the
	// draws are refused and half are accepted. A uniform uint64 would never
	// fall below it.
	prop := func(draw uint64) bool {
		hard := draw % (2 * minNofile)
		soft, err := nofileSoft(hard)
		if hard < minNofile {
			return err != nil
		}

		return err == nil && soft == hard
	}

	cfg := &quick.Config{MaxCount: 2000, Rand: rand.New(rand.NewSource(85))}
	if err := quick.Check(prop, cfg); err != nil {
		t.Fatal(err)
	}
}

// TestNofileSoftEdges pins the boundary the property only samples.
func TestNofileSoftEdges(t *testing.T) {
	if _, err := nofileSoft(minNofile - 1); err == nil {
		t.Fatal("a hard limit one below the minimum was accepted")
	}

	if soft, err := nofileSoft(minNofile); err != nil || soft != minNofile {
		t.Fatalf("the minimum itself: soft=%d err=%v", soft, err)
	}

	// The 4,096 hard limit the exe.dev box has, which failed a real boot.
	if _, err := nofileSoft(4096); err == nil {
		t.Fatal("a hard limit of 4096 was accepted")
	}
}
