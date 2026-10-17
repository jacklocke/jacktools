# Segmenti powerline personalizzati: disco, RAM e data in italiano.
import os
import time

GIORNI = ('Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom')


def disk_usage(pl, path='/', format='🗄 {0:.0f}%'):
	'''Occupazione del filesystem in percentuale.

	Highlight groups used: ``disk_usage_gradient`` (gradient).
	'''
	st = os.statvfs(path)
	total = st.f_blocks * st.f_frsize
	if not total:
		return None
	pct = (st.f_blocks - st.f_bfree) * st.f_frsize * 100.0 / total
	return [{
		'contents': format.format(pct),
		'gradient_level': pct,
		'highlight_groups': ['disk_usage_gradient'],
	}]


def ram_usage(pl, format='RAM {0:.0f}%'):
	'''RAM usata in percentuale (esclusa la cache).

	Highlight groups used: ``ram_usage_gradient`` (gradient).
	'''
	# Same value as psutil.virtual_memory().percent, without needing python3-psutil.
	info = {}
	with open('/proc/meminfo') as f:
		for line in f:
			key, value = line.split(':', 1)
			info[key] = int(value.split()[0])
	total = info.get('MemTotal', 0)
	if not total:
		return None
	pct = (total - info.get('MemAvailable', info.get('MemFree', 0))) * 100.0 / total
	return [{
		'contents': format.format(pct),
		'gradient_level': pct,
		'highlight_groups': ['ram_usage_gradient'],
	}]


def date_it(pl, format='{giorno} %d/%m'):
	'''Data con il giorno della settimana in italiano, senza dipendere dal locale.

	Highlight groups used: ``date``.
	'''
	now = time.localtime()
	return [{
		'contents': time.strftime(format.replace('{giorno}', GIORNI[now.tm_wday]), now),
		'highlight_groups': ['date'],
	}]
