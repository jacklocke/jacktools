#!/usr/bin/env python3
# Genera colors.json e i colorschemes powerline (comune, tmux, shell) per ogni palette.
# Per aggiungere o ritoccare uno schema: modifica PALETTES e rilancia lo script.
import json
import os

BASE = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'powerline')

# ruolo: (colore 256, hex) oppure solo 'hex' (il colore 256 più vicino viene calcolato). bg = sfondo barra, line = sfondo segmenti, muted = testo secondario,
# accent = colore principale (utente, ora, finestra attiva), accent2 = secondario (host, cartella corrente).
PALETTES = {
	'dracula': {
		'bg': (236, '282a36'), 'line': (238, '44475a'), 'fg': (255, 'f8f8f2'), 'muted': (61, '6272a4'),
		'accent': (141, 'bd93f9'), 'accent2': (212, 'ff79c6'), 'green': (84, '50fa7b'),
		'yellow': (228, 'f1fa8c'), 'orange': (215, 'ffb86c'), 'red': (203, 'ff5555'), 'cyan': (117, '8be9fd'),
	},
	'nord': {
		'bg': (236, '2e3440'), 'line': (237, '3b4252'), 'fg': (255, 'eceff4'), 'muted': (240, '4c566a'),
		'accent': (110, '88c0d0'), 'accent2': (109, '81a1c1'), 'green': (144, 'a3be8c'),
		'yellow': (222, 'ebcb8b'), 'orange': (173, 'd08770'), 'red': (131, 'bf616a'), 'cyan': (109, '8fbcbb'),
	},
	'tokyonight': {
		'bg': (234, '1a1b26'), 'line': (236, '292e42'), 'fg': (153, 'c0caf5'), 'muted': (60, '565f89'),
		'accent': (111, '7aa2f7'), 'accent2': (141, 'bb9af7'), 'green': (149, '9ece6a'),
		'yellow': (179, 'e0af68'), 'orange': (215, 'ff9e64'), 'red': (210, 'f7768e'), 'cyan': (117, '7dcfff'),
	},
	'gruvbox': {
		'bg': (235, '282828'), 'line': (237, '3c3836'), 'fg': (223, 'ebdbb2'), 'muted': (241, '665c54'),
		'accent': (214, 'fabd2f'), 'accent2': (208, 'fe8019'), 'green': (142, 'b8bb26'),
		'yellow': (214, 'fabd2f'), 'orange': (208, 'fe8019'), 'red': (167, 'fb4934'), 'cyan': (108, '8ec07c'),
	},
	'onedark': {
		'bg': (235, '282c34'), 'line': (238, '3e4452'), 'fg': (249, 'abb2bf'), 'muted': (59, '5c6370'),
		'accent': (75, '61afef'), 'accent2': (176, 'c678dd'), 'green': (114, '98c379'),
		'yellow': (180, 'e5c07b'), 'orange': (173, 'd19a66'), 'red': (168, 'e06c75'), 'cyan': (73, '56b6c2'),
	},
	'solarized': {
		'bg': (234, '002b36'), 'line': (235, '073642'), 'fg': (254, 'eee8d5'), 'muted': (240, '586e75'),
		'accent': (32, '268bd2'), 'accent2': (162, 'd33682'), 'green': (100, '859900'),
		'yellow': (136, 'b58900'), 'orange': (166, 'cb4b16'), 'red': (160, 'dc322f'), 'cyan': (37, '2aa198'),
	},
	'catppuccin': {
		'bg': '1e1e2e', 'line': '313244', 'fg': 'cdd6f4', 'muted': '585b70',
		'accent': 'cba6f7', 'accent2': 'f5c2e7', 'green': 'a6e3a1',
		'yellow': 'f9e2af', 'orange': 'fab387', 'red': 'f38ba8', 'cyan': '89dceb',
	},
	'rosepine': {
		'bg': '191724', 'line': '26233a', 'fg': 'e0def4', 'muted': '6e6a86',
		'accent': 'c4a7e7', 'accent2': 'ebbcba', 'green': '9ccfd8',
		'yellow': 'f6c177', 'orange': 'ebbcba', 'red': 'eb6f92', 'cyan': '9ccfd8',
	},
	'kanagawa': {
		'bg': '1f1f28', 'line': '2a2a37', 'fg': 'dcd7ba', 'muted': '54546d',
		'accent': '7e9cd8', 'accent2': '957fb8', 'green': '98bb6c',
		'yellow': 'e6c384', 'orange': 'ffa066', 'red': 'e46876', 'cyan': '7fb4ca',
	},
	'everforest': {
		'bg': '2d353b', 'line': '3d484d', 'fg': 'd3c6aa', 'muted': '7a8478',
		'accent': 'a7c080', 'accent2': 'd699b6', 'green': '83c092',
		'yellow': 'dbbc7f', 'orange': 'e69875', 'red': 'e67e80', 'cyan': '7fbbb3',
	},
	'monokai': {
		'bg': '272822', 'line': '3e3d32', 'fg': 'f8f8f2', 'muted': '75715e',
		'accent': 'ae81ff', 'accent2': 'f92672', 'green': 'a6e22e',
		'yellow': 'e6db74', 'orange': 'fd971f', 'red': 'f92672', 'cyan': '66d9ef',
	},
	'material': {
		'bg': '0f111a', 'line': '1f2233', 'fg': 'a6accd', 'muted': '464b5d',
		'accent': '82aaff', 'accent2': 'c792ea', 'green': 'c3e88d',
		'yellow': 'ffcb6b', 'orange': 'f78c6c', 'red': 'ff5370', 'cyan': '89ddff',
	},
	'ayu': {
		'bg': '1f2430', 'line': '2d3343', 'fg': 'cccac2', 'muted': '707a8c',
		'accent': '73d0ff', 'accent2': 'ffa759', 'green': 'd5ff80',
		'yellow': 'ffd173', 'orange': 'ffad66', 'red': 'f28779', 'cyan': '95e6cb',
	},
	'synthwave': {
		'bg': '262335', 'line': '34294f', 'fg': 'ffffff', 'muted': '848bbd',
		'accent': 'ff7edb', 'accent2': '36f9f6', 'green': '72f1b8',
		'yellow': 'fede5d', 'orange': 'ff8b39', 'red': 'fe4450', 'cyan': '03edf9',
	},
	# Temi chiari: il testo sui blocchi colorati usa bg, quindi resta chiaro
	'solarized_light': {
		'bg': 'fdf6e3', 'line': 'eee8d5', 'fg': '073642', 'muted': '93a1a1',
		'accent': '268bd2', 'accent2': 'd33682', 'green': '859900',
		'yellow': 'b58900', 'orange': 'cb4b16', 'red': 'dc322f', 'cyan': '2aa198',
	},
	'github_light': {
		'bg': 'ffffff', 'line': 'eaeef2', 'fg': '24292f', 'muted': '8c959f',
		'accent': '0969da', 'accent2': '8250df', 'green': '1a7f37',
		'yellow': '9a6700', 'orange': 'bc4c00', 'red': 'cf222e', 'cyan': '1b7c83',
	},
}

GRADIENT = 'green_yellow_orange_red'


def nearest_256(hexval):
	'''Colore xterm-256 più vicino all'hex dato (cubo 6x6x6 o scala di grigi).'''
	rgb = [int(hexval[i:i + 2], 16) for i in (0, 2, 4)]
	levels = [0, 95, 135, 175, 215, 255]
	cube = [min(range(6), key=lambda i: abs(levels[i] - v)) for v in rgb]
	cands = [(16 + 36 * cube[0] + 6 * cube[1] + cube[2], [levels[i] for i in cube])]
	gray = min(range(24), key=lambda i: abs(8 + 10 * i - sum(rgb) / 3))
	cands.append((232 + gray, [8 + 10 * gray] * 3))
	return min(cands, key=lambda c: sum((a - b) ** 2 for a, b in zip(c[1], rgb)))[0]


def g(fg, bg, *attrs):
	return {'fg': fg, 'bg': bg, 'attrs': list(attrs)}


def common_groups(c):
	return {
		'information:additional': g(c('fg'), c('line')),
		'information:regular': g(c('fg'), c('line'), 'bold'),
		'information:highlighted': g(c('fg'), c('line'), 'bold'),
		'information:unimportant': g(c('muted'), c('line')),
		'information:priority': g(c('bg'), c('yellow')),
		'warning:regular': g(c('bg'), c('orange')),
		'critical:failure': g(c('bg'), c('red'), 'bold'),
		'critical:success': g(c('bg'), c('green')),
		'background': g(c('fg'), c('bg')),
		'background:divider': g(c('muted'), c('bg')),
		'hostname': g(c('bg'), c('accent2'), 'bold'),
		'user': g(c('bg'), c('accent'), 'bold'),
		'virtualenv': g(c('bg'), c('green')),
		'environment': g(c('bg'), c('green')),
		'attached_clients': g(c('bg'), c('green')),
		'branch': g(c('fg'), c('muted')),
		'branch_clean': g(c('fg'), c('muted')),
		'branch_dirty': g(c('yellow'), c('muted'), 'bold'),
		'branch:divider': g(c('line'), c('muted')),
		'stash': 'branch_dirty',
		'cwd': g(c('fg'), c('line')),
		'cwd:current_folder': g(c('accent2'), c('line'), 'bold'),
		'cwd:divider': g(c('muted'), c('line')),
		'system_load': g(c('fg'), c('line')),
		'cpu_load_percent': g(c('fg'), c('line')),
		'cpu_load_percent_gradient': g(GRADIENT, c('line')),
		'ram_usage_gradient': g(GRADIENT, c('line')),
		'disk_usage_gradient': g(GRADIENT, c('line')),
		'uptime': g(c('cyan'), c('line')),
		'date': g(c('fg'), c('muted')),
		'time': g(c('bg'), c('accent'), 'bold'),
		'time:divider': g(c('bg'), c('accent')),
	}


def tmux_groups(c):
	return {
		'active_window_status': g(c('accent'), c('bg')),
		'window_status': g(c('muted'), c('bg')),
		'activity_status': g(c('yellow'), c('bg')),
		'bell_status': g(c('red'), c('bg')),
		'window': g(c('fg'), c('bg')),
		'window:divider': g(c('muted'), c('bg')),
		'window:current': g(c('bg'), c('accent')),
		'window_name': g(c('bg'), c('accent'), 'bold'),
		'session': g(c('bg'), c('green'), 'bold'),
		'session:prefix': g(c('bg'), c('yellow'), 'bold'),
	}


def shell_groups(c):
	return {
		'mode': g(c('bg'), c('green'), 'bold'),
		'prompt_char': g(c('bg'), c('accent'), 'bold'),
	}


def write(path, data):
	os.makedirs(os.path.dirname(path), exist_ok=True)
	with open(path, 'w') as f:
		json.dump(data, f, indent='\t', ensure_ascii=False)
		f.write('\n')


def main():
	colors = {}
	for name, pal in PALETTES.items():
		for role, value in pal.items():
			cterm, hexval = (nearest_256(value), value) if isinstance(value, str) else value
			colors['%s:%s' % (name, role)] = [cterm, hexval]

		def c(role, name=name):
			return '%s:%s' % (name, role)

		write(os.path.join(BASE, 'colorschemes', name + '.json'), {'name': name, 'groups': common_groups(c)})
		write(os.path.join(BASE, 'colorschemes', 'tmux', name + '.json'), {'groups': tmux_groups(c)})
		write(os.path.join(BASE, 'colorschemes', 'shell', name + '.json'), {
			'name': name + ' for shell',
			'groups': shell_groups(c),
			'mode_translations': {'vicmd': {'groups': {'mode': g(c('bg'), c('cyan'), 'bold')}}},
		})
	write(os.path.join(BASE, 'colors.json'), {'colors': colors})
	print('Schemi generati: ' + ', '.join(PALETTES))


if __name__ == '__main__':
	main()
