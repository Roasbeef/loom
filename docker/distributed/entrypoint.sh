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
# distribution (docs/configuration.md, "[distribution]"). Every workspace root
# the installed configuration names is created if it is missing, so an
# executor starts before any project has been copied into it.
#
# The orchestrator also mounts /config/loom.toml, a model catalogue and role
# routes. It is copied to ~/.loom/loom.toml before the install, which appends
# the bundle's own tables to it and leaves these alone. A fixture directory
# carries its own loom.toml, so the mount is ignored for one.
#
# LOOM_CGROUP_DELEGATE=1 (compose.isolated.yaml) additionally carves out the
# cgroup v2 base the full-isolation posture needs (docs/docker.md), inside the
# container's own cgroup, and refuses to run if the container shares the
# host's cgroup namespace.
set -eu

uid=10000
gid=10000
home=/home/loom
bundle=/bundle
config_in=/config/loom.toml

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
		if [ -f "$config_in" ]; then
			install -m 0600 -o "$uid" -g "$gid" "$config_in" "$home/.loom/loom.toml"
		fi
	fi
	chown -R "$uid:$gid" "$home"

	if [ "${LOOM_CGROUP_DELEGATE:-0}" = 1 ]; then
		# Everything below writes under /sys/fs/cgroup. In a private cgroup
		# namespace that directory is this container's own cgroup, and the
		# kernel reports it as "0::/". Anything else means the container
		# shares the host's cgroup tree, where moving processes and creating
		# directories would change the host, so the script refuses to go on.
		if [ "$(cat /proc/self/cgroup)" != "0::/" ]; then
			echo "entrypoint: LOOM_CGROUP_DELEGATE=1 needs a private cgroup namespace (compose.isolated.yaml sets cgroup: private); this container shares the host's cgroup tree" >&2
			exit 70
		fi

		# The delegated base must hold no process itself, and neither may the
		# cgroup above it when it hands controllers down. The daemon and the
		# helper therefore live in a leaf, loom/host, and every process the
		# container already has (tini, this script) moves into it. The daemon
		# is a descendant and inherits that cgroup. LOOM_CGROUP_BASE names the
		# base for loom-exec, which otherwise takes the daemon's own cgroup
		# (the leaf) and finds it occupied.
		mount -o remount,rw /sys/fs/cgroup
		mkdir -p /sys/fs/cgroup/loom/host
		members=$(cat /sys/fs/cgroup/cgroup.procs)
		for member in $members; do
			echo "$member" >/sys/fs/cgroup/loom/host/cgroup.procs 2>/dev/null || true
		done
		echo "+pids +memory" >/sys/fs/cgroup/cgroup.subtree_control
		echo "+pids +memory" >/sys/fs/cgroup/loom/cgroup.subtree_control
		chown -R "$uid:$gid" /sys/fs/cgroup/loom
		export LOOM_CGROUP_BASE=/sys/fs/cgroup/loom
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
	# role tables, and writes the options file next to the certificates, which
	# is not where `loomd distribution options` puts it. This is the install's
	# default directory, so a plan that sets its own bundle_dir needs this line
	# changed with it.
	loomd distribution install "$HOME/node.loombundle"
	rm -f "$HOME/node.loombundle"
	optfile="$HOME/.loom/distribution/dist.options"
else
	loomd distribution options "$config" "$optfile"
fi

export LOOM_DISTRIBUTION_OPTFILE="$optfile"

# The daemon refuses to start when a workspace root is not a directory, and
# the project is normally copied in after the container is up. Creating each
# missing root here lets the executor start first. The directory belongs to
# the daemon's uid, which is the owner a project streamed in afterwards has to
# have for the daemon to write its .blobs directory inside it. Only the
# [workspaces.NAME] tables of the installed configuration are read.
awk '
	/^\[workspaces\./ { in_workspace = 1; next }
	/^\[/ { in_workspace = 0 }
	in_workspace && /^root *= *"/ {
		sub(/^root *= *"/, "")
		sub(/"[ \t]*$/, "")
		print
	}
' "$config" | xargs -r -d '\n' mkdir -p || {
	echo "entrypoint: cannot create a workspace root; if /work is a host directory, make it writable by uid $uid" >&2
	exit 73
}

# The daemon binds loopback only (docs/docker.md, "The bind restriction").
# Peers reach this node through distribution, not through this port.
exec loomd --state-dir /var/lib/loom --bind 127.0.0.1:7331 --config "$config" "$@"
