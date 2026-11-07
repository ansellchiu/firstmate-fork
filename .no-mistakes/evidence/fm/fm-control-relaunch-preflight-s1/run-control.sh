#!/usr/bin/env bash
# Run the real bin/fm-control.sh against the lab home and lab tmux socket.
LAB=$1; shift
SOCK="$LAB/tmux/tmux-$(id -u)/fm-lab"
PID=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p '#{pid}')
exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" TMUX="$SOCK,$PID,0" FM_HOME="$LAB" bin/fm-control.sh "$@"
