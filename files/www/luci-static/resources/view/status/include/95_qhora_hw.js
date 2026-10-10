'use strict';
'require baseclass';
'require fs';

/*
 * 「状态 → 总览」首页的硬件区块：CPU 占用率 / 温度传感器 / 内存。
 *
 * 为什么是本仓库自己写的：
 *   官方 LuCI 的总览页（modules/luci-mod-status 的 10_system.js）只有主机名、
 *   型号、内核、时间、运行时长、负载均值这几项，**没有** CPU 占用率和温度。
 *   ImmortalWrt 那份 10_system.js 有，但它走的是 ubus 的 luci.getCPUUsage /
 *   luci.getTempInfo —— 这两个方法是 ImmortalWrt 给 rpcd-mod-luci 打的补丁，
 *   官方 openwrt/luci 的 rpcd-mod-luci 里没有（只有 getBoardJSON 等），
 *   所以照抄过来只会一直显示 "?"。
 *
 *   官方总览页的 include 列表不是写死的：index.js 用
 *   fs.list('/www/luci-static/resources/view/status/include') 扫目录，
 *   按文件名排序后逐个 L.require()。因此把本文件放进这个目录，
 *   首页就会自动多出这一块 —— 不用改任何上游文件。
 *
 * 数据来源（都是只读的 procfs / sysfs，走 rpcd 的 file.read）：
 *   /proc/stat                                    CPU 时间片，两次采样做差得占用率
 *   /sys/devices/system/cpu/cpufreq/policy<N>/     CPU 当前频率
 *   /sys/class/thermal/thermal_zone<N>/{type,temp} SoC 各温度区（cpu / nss / wifi …）
 *   /sys/class/hwmon/hwmon<N>/{name,temp<N>_input}  部分驱动的温度只在 hwmon 里
 *   /proc/meminfo                                 内存总量 / 可用
 * 这些路径的读权限由 files/usr/share/rpcd/acl.d/qhora-overview.json 授权
 * （官方 luci-base 那组只给了 list，没给 read）。
 */

var THERMAL_DIR  = '/sys/class/thermal';
var HWMON_DIR    = '/sys/class/hwmon';
var CPUFREQ_DIR  = '/sys/devices/system/cpu/cpufreq';
var PROC_STAT    = '/proc/stat';
var PROC_MEMINFO = '/proc/meminfo';

/* 上一次的 /proc/stat 样本。首页每轮轮询都会重新 load()，用两次采样做差
 * 得到的就是这段时间的平均占用率；模块级变量在轮询之间是保留的。 */
var lastSample = null;

function readFile(path) {
	return L.resolveDefault(fs.read(path), null);
}

function listDir(path) {
	return L.resolveDefault(fs.list(path), []);
}

function toNum(s) {
	var v = parseInt(String(s == null ? '' : s).trim(), 10);
	return isNaN(v) ? null : v;
}

/* thermal_zone<N>/temp 是毫摄氏度；个别驱动直接给摄氏度，用大小判断 */
function toCelsius(raw) {
	return (raw > 1000) ? raw / 1000 : raw;
}

function compact(list) {
	var out = [];
	for (var i = 0; i < list.length; i++)
		if (list[i] != null)
			out.push(list[i]);
	return out;
}

function dirEntries(base, pattern) {
	return listDir(base).then(function(entries) {
		var out = [];
		for (var i = 0; i < entries.length; i++)
			if (pattern.test(entries[i].name))
				out.push(entries[i].name);
		return out.sort();
	});
}

function sampleCPU() {
	return readFile(PROC_STAT).then(function(data) {
		var m = (data || '').match(/^cpu\s+(.+)$/m);
		if (!m)
			return null;

		var v = m[1].trim().split(/\s+/).map(toNum);
		if (v.length < 4 || v[0] == null)
			return null;

		var idle = (v[3] || 0) + (v[4] || 0), total = 0;
		for (var i = 0; i < v.length; i++)
			total += (v[i] || 0);

		return (total > 0) ? { idle: idle, total: total } : null;
	});
}

function deltaCPU(a, b) {
	if (!a || !b || b.total <= a.total)
		return null;

	var used = 1 - (b.idle - a.idle) / (b.total - a.total);
	return Math.max(0, Math.min(100, used * 100));
}

function cpuUsage() {
	var prev = lastSample;

	return sampleCPU().then(function(now) {
		if (prev) {
			if (now)
				lastSample = now;
			return deltaCPU(prev, now);
		}

		/* 首次打开没有历史样本：隔 250ms 再采一次，让首屏也有数字 */
		return new Promise(function(resolve) {
			setTimeout(resolve, 250);
		}).then(sampleCPU).then(function(next) {
			if (next)
				lastSample = next;
			return deltaCPU(now, next);
		});
	});
}

function cpuFreq() {
	return dirEntries(CPUFREQ_DIR, /^policy\d+$/).then(function(dirs) {
		return Promise.all(dirs.map(function(d) {
			return readFile(CPUFREQ_DIR + '/' + d + '/scaling_cur_freq').then(function(s) {
				var khz = toNum(s);
				return (khz == null) ? null : Math.round(khz / 1000);
			});
		})).then(compact);
	});
}

function thermalZones() {
	return dirEntries(THERMAL_DIR, /^thermal_zone\d+$/).then(function(zones) {
		return Promise.all(zones.map(function(z) {
			var base = THERMAL_DIR + '/' + z;

			return Promise.all([ readFile(base + '/type'), readFile(base + '/temp') ]).then(function(v) {
				var raw = toNum(v[1]);
				if (raw == null)
					return null;

				var name = (v[0] || '').trim();
				return { label: name || z, celsius: toCelsius(raw) };
			});
		})).then(compact);
	});
}

function hwmonTemps() {
	return dirEntries(HWMON_DIR, /^hwmon\d+$/).then(function(chips) {
		return Promise.all(chips.map(function(c) {
			var base = HWMON_DIR + '/' + c;

			return readFile(base + '/name').then(function(n) {
				var chip = (n || '').trim() || c;

				return dirEntries(base, /^temp\d+_input$/).then(function(files) {
					return Promise.all(files.map(function(f) {
						return readFile(base + '/' + f).then(function(s) {
							var raw = toNum(s);
							if (raw == null)
								return null;
							return { label: chip + ' ' + f.replace('_input', ''), celsius: toCelsius(raw) };
						});
					})).then(compact);
				});
			});
		})).then(function(lists) {
			var out = [];
			for (var i = 0; i < lists.length; i++)
				out = out.concat(lists[i]);
			return out;
		});
	});
}

function memory() {
	return readFile(PROC_MEMINFO).then(function(data) {
		if (!data)
			return null;

		var kv = {};
		var lines = data.split('\n');
		for (var i = 0; i < lines.length; i++) {
			var m = lines[i].match(/^([A-Za-z_()0-9]+):\s+(\d+)/);
			if (m)
				kv[m[1]] = parseInt(m[2], 10) * 1024;	/* kB → 字节 */
		}

		if (!kv.MemTotal)
			return null;

		var available = (kv.MemAvailable != null) ? kv.MemAvailable : (kv.MemFree || 0);
		return { total: kv.MemTotal, used: Math.max(0, kv.MemTotal - available) };
	});
}

function mib(bytes) {
	return (bytes / 1048576).toFixed(1);
}

function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
		E('td', { 'class': 'td left' }, [ (value != null) ? value : '?' ])
	]);
}

return baseclass.extend({
	/* 本文件由本仓库自己维护、不走上游 luci.mk，没有 po 词条；
	 * 标题直接用中文，免得在中文界面里冒出一行英文。
	 * 行标签尽量复用上游**已有译文**的 msgid：
	 *   'CPU usage (%)' → 官方 luci-base 的 zh_Hans 词条里就有；
	 *   'Memory'        → 同上。
	 * 温度行的标签用内核给的传感器名（cpu-thermal / wifi-thermal …），与语言无关。 */
	title: 'CPU / 温度 / 内存',

	load: function() {
		return Promise.all([
			cpuUsage(),
			cpuFreq(),
			thermalZones(),
			hwmonTemps(),
			memory()
		]);
	},

	render: function(data) {
		var usage  = data[0],
		    freqs  = data[1] || [],
		    zones  = data[2] || [],
		    hwmons = data[3] || [],
		    mem    = data[4];

		var cpuText = null;
		if (usage != null) {
			cpuText = usage.toFixed(1) + ' %';
			if (freqs.length)
				cpuText += ' · ' + freqs.join(' / ') + ' MHz';
		}
		else if (freqs.length) {
			cpuText = freqs.join(' / ') + ' MHz';
		}

		var table = E('table', { 'class': 'table' });
		table.appendChild(row(_('CPU usage (%)'), cpuText));

		var sensors = zones.concat(hwmons);
		for (var i = 0; i < sensors.length; i++)
			table.appendChild(row(sensors[i].label, sensors[i].celsius.toFixed(1) + ' °C'));

		if (mem) {
			var pct = (mem.total > 0) ? (mem.used / mem.total * 100) : 0;
			table.appendChild(row(_('Memory'),
				mib(mem.used) + ' / ' + mib(mem.total) + ' MiB (' + pct.toFixed(1) + ' %)'));
		}

		return table;
	}
});
