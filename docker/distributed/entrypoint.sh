#!/bin/sh
# entrypoint.sh: start one distributed Loom node inside the loom-runtime image.
#
# docker/distributed/compose.yaml bind-mounts this file at /entrypoint.sh and
# mounts the node's provisioned bundle read-only at /bundle. The script runs
# twice. As root it copies the bundle into the loom user's home, because the
# bundle is owned by whoever ran the provisioning command on the host and the
# daemon insists on private files it can read. It then drops to uid 10000 and
# runs itself again, and that second pass installs the bundle and starts the
# daemon.
#
# /bundle is one of two things:
#
#   a file, NODE.loombundle          The output of `loom distribution provision`.
#                                    `loomd distribution install` unpacks it.
#   a directory with home/ inside    The openssl fixture that
#                                    scripts/distributed/mint-fixture.sh writes.
#                                    The smoke test uses it, so a pair boots
#                                    without the provision command.
#
# Either way the daemon starts through the release launcher with
# LOOM_DISTRIBUTION_OPTFILE set, which is what boots the VM on TLS
# distribution (docs/configuration.md, "[distribution]").
#
# LOOM_CGROUP_DELEGATE=1 (compose.isolated.yaml) additionally carves out the
# cgroup v2 base the full-isolation posture needs (docs/docker.md). That step
# has not been verified end to end from this entrypoint.
set -eu

uid=10000
gid=10000
home=/home/loom
bundle=/bundle

if [ "$(id -u)" = 0 ]; then
	if [ ! -e "$bundle" ]; then
		echo "entrypoint: nothing is mounted at $bundle; provision the deployment and mount this node's bundle" >&2
		exit 66
	fi
	install -d -m 0700 -o "$uid" -g "$gid" "$home" "$home/.loom"
	if [ -d "$bundle" ]; then
		if [ ! -d "$bundle/home" ]; then
			echo "entrypoint: $bundle is a directory without home/; it is not a provisioned bundle" >&2
			exit 66
		fi
		cp -a "$bundle/home/." "$home/"
	else
		install -m 0600 -o "$uid" -g "$gid" "$bundle" "$home/node.loombundle"
	fi
	chown -R "$uid:$gid" "$home"

	if [ "${LOOM_CGROUP_DELEGATE:-0}" = 1 ]; then
		mount -o remount,rw /sys/fs/cgroup
		mkdir -p /sys/fs/cgroup/loom/host
		echo "+pids +memory" >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
		echo "+pids +memory" >/sys/fs/cgroup/loom/cgroup.subtree_control
		chown -R "$uid:$gid" /sys/fs/cgroup/loom
	fi

	# The second pass runs unprivileged. HOME is set explicitly because the
	# VM reads its cookie from $HOME/.erlang.cookie and nothing else.
	exec setpriv --reuid="$uid" --regid="$gid" --clear-groups \
		env HOME="$home" "$0" "$@"
fi

export HOME="$home"
config="$HOME/.loom/loom.toml"
optfile="$HOME/.loom/distribution.options"

if [ -f "$HOME/node.loombundle" ]; then
	# Unpacks the certificates, the cookie at $HOME/.erlang.cookie and the
	# role tables, and writes the options file. Not yet verified against the
	# shipped command: the path of the options file is assumed to be the one
	# docs/configuration.md uses.
	loomd distribution install "$HOME/node.loombundle"
	rm -f "$HOME/node.loombundle"
else
	loomd distribution options "$config" "$optfile"
fi

export LOOM_DISTRIBUTION_OPTFILE="$optfile"

# The daemon binds loopback only (docs/docker.md, "The bind restriction").
# Peers reach this node through distribution, not through this port.
exec loomd --state-dir /var/lib/loom --bind 127.0.0.1:7331 --config "$config" "$@"
