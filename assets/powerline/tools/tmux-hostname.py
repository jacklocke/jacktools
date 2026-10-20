#!/usr/bin/env python3
# Mette l'hostname davanti alla sessione nella barra di tmux e, a destra, i badge ZOOM
# (pane ingrandito), SYNC (scrittura su tutti i pane) e client collegati, con i colori del tema.
# Va lanciato da ~/.tmux.conf dopo il source di powerline.conf (che riscrive status-left/right).
import json
import os
import subprocess

BASE = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'powerline')
DIVIDER = ''
MARK = ' #h '
BADGE_MARK = '#{window_zoomed_flag}'
# Ogni badge compare solo quando la sua condizione è vera.
BADGES = (
	('badge_zoom', '#{window_zoomed_flag}', ' ZOOM '),
	('badge_sync', '#{pane_synchronized}', ' SYNC '),
	('badge_clients', '#{>:#{session_attached},1}', ' 👥 #{session_attached} '),
)


def load(path):
	with open(os.path.join(BASE, path)) as f:
		return json.load(f)


def tmux(*args):
	return subprocess.run(('tmux',) + args, capture_output=True, text=True).stdout.rstrip('\n')


def option(name):
	# show -v scrive $ come \$: senza togliere l'escape, la riscrittura romperebbe #(env $POWERLINE_COMMAND ...)
	return tmux('show', '-gv', name).replace('\\$', '$')


def main():
	theme = load('config.json')['ext']['tmux']['colorscheme']
	colors = load('colors.json')['colors']
	common = load('colorschemes/%s.json' % theme)['groups']
	session = load('colorschemes/tmux/%s.json' % theme)['groups']

	def cterm(name):
		value = colors[name]
		return value[0] if isinstance(value, list) else value

	host_fg = cterm(common['hostname']['fg'])
	host_bg = cterm(common['hostname']['bg'])
	sess_bg = cterm(session['session']['bg'])
	prefix_bg = cterm(session['session:prefix']['bg'])

	right = option('status-right')
	if BADGE_MARK not in right:
		badges = ''
		for group, cond, text in BADGES:
			style = common.get(group)
			if style:
				badges += '#{?%s,#[fg=colour%d#,bg=colour%d#,bold]%s#[default] ,}' % (
					cond, cterm(style['fg']), cterm(style['bg']), text)
		tmux('set', '-g', 'status-right', badges + right)

	left = option('status-left')
	if MARK in left:
		return
	host = (
		'#[fg=colour%d,bg=colour%d,bold]%s#[nobold]'
		'#[fg=colour%d]#{?client_prefix,#[bg=colour%d],#[bg=colour%d]}%s'
	) % (host_fg, host_bg, MARK, host_bg, prefix_bg, sess_bg, DIVIDER)
	tmux('set', '-g', 'status-left', host + left)
	tmux('set', '-g', 'status-left-length', '40')


if __name__ == '__main__':
	main()
