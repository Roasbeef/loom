package setup

import (
	"context"
	"fmt"
	"os"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

// The OCI labels the guest Dockerfile sets. Revision is the loom commit the
// image was built from; version is the release tag it was built for.
const (
	labelRevision = "org.opencontainers.image.revision"
	labelVersion  = "org.opencontainers.image.version"
)

// GuestImageRef is the registry reference of a release's guest image. The
// image lives under the release repository's owner, as
// ghcr.io/<owner>/loom-guest:<tag>.
//
// ## Examples
//
//	setup.GuestImageRef("roasbeef", "v0.3.0") // ghcr.io/roasbeef/loom-guest:v0.3.0
func GuestImageRef(owner, tag string) string {
	return fmt.Sprintf("ghcr.io/%s/loom-guest:%s", owner, tag)
}

// pullGuest fetches the guest image for goarch from ref, anonymously, and
// returns it with the revision its labels record.
//
// The image is anonymous because a release's guest image is public; a stale
// credential in the user's docker config must not turn a public pull into a
// 401. The labels are checked here because they are the only link between
// the bytes and the release: an image missing them was not built by the
// release workflow, and one whose version differs from the requested tag is
// some other release's root under this tag's name.
func pullGuest(ctx context.Context, ref, tag, goarch string) (v1.Image, string, error) {
	parsed, err := name.ParseReference(ref)
	if err != nil {
		return nil, "", fmt.Errorf("guest image %q: %w", ref, err)
	}

	img, err := remote.Image(parsed,
		remote.WithContext(ctx),
		remote.WithAuth(authn.Anonymous),
		remote.WithPlatform(v1.Platform{OS: "linux", Architecture: goarch}),
	)
	if err != nil {
		return nil, "", fmt.Errorf("pull %s for linux/%s: %w", ref, goarch, err)
	}

	cfg, err := img.ConfigFile()
	if err != nil {
		return nil, "", fmt.Errorf("read the config of %s: %w", ref, err)
	}

	labels := cfg.Config.Labels
	if labels[labelRevision] == "" {
		return nil, "", fmt.Errorf("%s has no %s label; it was not built by the release workflow",
			ref, labelRevision)
	}

	if got := labels[labelVersion]; got != tag {
		return nil, "", fmt.Errorf("%s is version %q, not %q", ref, got, tag)
	}

	return img, labels[labelRevision], nil
}

// extractGuest flattens img's layers and unpacks the result into dir.
func extractGuest(img v1.Image, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	tarball := mutate.Extract(img)
	defer tarball.Close()

	return ExtractRoot(tarball, dir)
}
