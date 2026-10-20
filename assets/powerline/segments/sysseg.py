# Segmenti powerline personalizzati: disco, RAM, data in italiano, Docker e temperatura.
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


# Container Docker: il demone powerline resta in vita, quindi il risultato
# viene tenuto in cache per non lanciare "docker ps" a ogni ridisegno.
_docker_cache = {'time': 0.0, 'value': None}


def docker_count(pl, format='🐳 {0}', interval=10):
	'''Numero di container in esecuzione; evidenziato se qualcuno è unhealthy.

	Highlight groups used: ``docker_warn`` or ``docker``.
	'''
	import shutil
	import subprocess
	now = time.monotonic()
	if now - _docker_cache['time'] >= interval:
		_docker_cache['time'] = now
		value = None
		if shutil.which('docker'):
			try:
				out = subprocess.run(
					['docker', 'ps', '--format', '{{.Status}}'],
					capture_output=True, text=True, timeout=3,
				)
				if out.returncode == 0:
					lines = out.stdout.splitlines()
					value = (len(lines), any('unhealthy' in line for line in lines))
			except (OSError, subprocess.SubprocessError):
				pass
		_docker_cache['value'] = value
	value = _docker_cache['value']
	if value is None:
		return None
	count, unhealthy = value
	return [{
		'contents': format.format(count),
		'highlight_groups': ['docker_warn' if unhealthy else 'docker', 'system_load'],
	}]


# Nome breve mostrato per ogni chip di sensori
_TEMP_NAMES = {
	'coretemp': 'CPU', 'k10temp': 'CPU', 'zenpower': 'CPU', 'cpu_thermal': 'CPU',
	'acpitz': 'MB', 'nvme': 'NVMe', 'drivetemp': 'Disco',
	'amdgpu': 'GPU', 'nouveau': 'GPU', 'radeon': 'GPU',
}


def temp_max(pl, format='🌡 {name} {temp:.0f}°', low=40):
	'''Temperatura del componente più caldo, con il suo nome (CPU, MB, NVMe, GPU...).

	I sensori dello stesso chip (es. i core della CPU) contano come un solo componente.
	Il colore va dal verde a ``low`` gradi al rosso al limite critico del sensore.

	Highlight groups used: ``temp_gradient`` (gradient).
	'''
	# Same sensors as psutil.sensors_temperatures(), read straight from hwmon.
	import glob

	def read_milli(path):
		try:
			with open(path) as f:
				return int(f.read()) / 1000.0
		except (OSError, ValueError):
			return None

	best = None
	for hwmon in glob.glob('/sys/class/hwmon/hwmon*'):
		try:
			with open(os.path.join(hwmon, 'name')) as f:
				chip = f.read().strip()
		except OSError:
			continue
		for inp in glob.glob(os.path.join(hwmon, 'temp*_input')):
			temp = read_milli(inp)
			if temp is None or temp <= 0:
				continue
			if best is None or temp > best[1]:
				base = inp[:-len('_input')]
				critical = read_milli(base + '_crit') or read_milli(base + '_max') or 95
				best = (_TEMP_NAMES.get(chip, chip), temp, critical)
	if best is None:
		return None
	name, temp, critical = best
	level = (temp - low) * 100.0 / max(critical - low, 1)
	return [{
		'contents': format.format(name=name, temp=temp),
		'gradient_level': max(0.0, min(100.0, level)),
		'highlight_groups': ['temp_gradient'],
	}]
