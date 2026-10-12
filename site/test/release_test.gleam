import gleam/list
import gleam/string
import site/release

pub fn the_tag_starts_with_a_v_test() {
  assert string.starts_with(release.tag, "v")
}

pub fn the_version_is_the_tag_without_its_v_test() {
  assert release.version_of("v0.2.1") == "0.2.1"
  assert release.version_of("0.2.1") == "0.2.1"
  assert release.version() == release.version_of(release.tag)
}

pub fn the_download_link_is_githubs_latest_release_redirect_test() {
  assert release.latest_url
    == "https://github.com/Roasbeef/loom/releases/latest"
}

pub fn archive_names_follow_distribution_md_test() {
  // docs/distribution.md names the three archives
  // `loomd-<version>-<platform>`, `loom-<version>-<platform>` and
  // `loom-slim-<version>-<platform>`, each with `.tar.gz`, and the manifest
  // `manifest-<platform>.json`.
  let version = release.version()
  assert release.server_archive("linux-x86_64")
    == "loomd-" <> version <> "-linux-x86_64.tar.gz"
  assert release.client_archive("macos-arm64")
    == "loom-" <> version <> "-macos-arm64.tar.gz"
  assert release.slim_archive("linux-x86_64")
    == "loom-slim-" <> version <> "-linux-x86_64.tar.gz"
  assert release.manifest("macos-arm64") == "manifest-macos-arm64.json"
}

pub fn source_links_name_the_main_branch_test() {
  assert release.source("docs/updating.md")
    == "https://github.com/Roasbeef/loom/blob/main/docs/updating.md"
  assert release.tree("docs")
    == "https://github.com/Roasbeef/loom/tree/main/docs"
}

pub fn the_platforms_are_the_ones_the_release_workflow_builds_test() {
  // .github/workflows/release.yml builds Linux x86_64 and macOS arm64.
  assert release.platforms == ["linux-x86_64", "macos-arm64"]
  assert list.length(release.platforms) == 2
}
