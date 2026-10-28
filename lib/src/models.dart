import 'dart:convert';

/// Информация о подписке из заголовков ответа Remnawave.
class SubscriptionInfo {
  const SubscriptionInfo({
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire,
    this.title,
    this.supportUrl,
    this.webPageUrl,
    this.announce,
    this.updateIntervalHours = 12,
  });

  final int upload;
  final int download;

  /// 0 = безлимит.
  final int total;
  final DateTime? expire;
  final String? title;
  final String? supportUrl;
  final String? webPageUrl;
  final String? announce;
  final int updateIntervalHours;

  int get used => upload + download;
  bool get unlimited => total == 0;
  bool get expired => expire != null && expire!.isBefore(DateTime.now());
  bool get trafficExhausted => !unlimited && used >= total;

  /// Разбор `subscription-userinfo: upload=0; download=1; total=2; expire=3`.
  static Map<String, int> parseUserInfo(String? raw) {
    final out = <String, int>{};
    if (raw == null) return out;
    for (final part in raw.split(';')) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final v = int.tryParse(kv[1].trim());
      if (v != null) out[kv[0].trim().toLowerCase()] = v;
    }
    return out;
  }

  /// Значения заголовков могут приходить как `base64:...`.
  static String? decodeHeader(String? v) {
    if (v == null || v.isEmpty) return null;
    if (v.startsWith('base64:')) {
      try {
        return utf8.decode(base64.decode(base64.normalize(v.substring(7))));
      } catch (_) {
        return null;
      }
    }
    return v;
  }

  factory SubscriptionInfo.fromHeaders(Map<String, String> h) {
    final ui = parseUserInfo(h['subscription-userinfo']);
    final exp = ui['expire'];
    return SubscriptionInfo(
      upload: ui['upload'] ?? 0,
      download: ui['download'] ?? 0,
      total: ui['total'] ?? 0,
      expire: (exp != null && exp > 0)
          ? DateTime.fromMillisecondsSinceEpoch(exp * 1000)
          : null,
      title: decodeHeader(h['profile-title']),
      supportUrl: h['support-url'],
      webPageUrl: h['profile-web-page-url'],
      announce: decodeHeader(h['announce']),
      updateIntervalHours: _firstInt(h['profile-update-interval']) ?? 12,
    );
  }

  /// Заголовок может прийти дважды ("6, 3") — берём первое число.
  static int? _firstInt(String? v) {
    final m = RegExp(r'\d+').firstMatch(v ?? '');
    return m == null ? null : int.tryParse(m.group(0)!);
  }

  Map<String, dynamic> toJson() => {
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire?.millisecondsSinceEpoch,
        'title': title,
        'supportUrl': supportUrl,
        'webPageUrl': webPageUrl,
        'announce': announce,
        'interval': updateIntervalHours,
      };

  factory SubscriptionInfo.fromJson(Map<String, dynamic> j) => SubscriptionInfo(
        upload: j['upload'] ?? 0,
        download: j['download'] ?? 0,
        total: j['total'] ?? 0,
        expire: j['expire'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(j['expire']),
        title: j['title'],
        supportUrl: j['supportUrl'],
        webPageUrl: j['webPageUrl'],
        announce: j['announce'],
        updateIntervalHours: j['interval'] ?? 12,
      );
}

/// Сохранённая на устройстве подписка (их может быть несколько).
class SavedSub {
  SavedSub({required this.id, required this.url, this.raw, this.info, this.variant});
  final String id;
  String url;
  String? raw;
  SubscriptionInfo? info;

  /// Какой вариант User-Agent сработал в прошлый раз (см. SubscriptionService.variants).
  String? variant;

  String get title => info?.title ?? Uri.tryParse(url)?.host ?? 'Подписка';

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'raw': raw,
        'info': info?.toJson(),
        'variant': variant,
      };

  factory SavedSub.fromJson(Map<String, dynamic> j) => SavedSub(
        id: j['id'] as String,
        url: j['url'] as String,
        raw: j['raw'] as String?,
        variant: j['variant'] as String?,
        info: j['info'] == null
            ? null
            : SubscriptionInfo.fromJson((j['info'] as Map).cast<String, dynamic>()),
      );
}

/// Удалённая конфигурация приложения. Админ задаёт её в Remnawave как
/// кастомный заголовок ответа подписки `x-relayfast-config`
/// (JSON либо `base64:<json>`).
///
/// ```json
/// {
///   "brand": {"name": "RelayFastVPN", "accent": "#2F7BFF",
///             "supportUrl": "https://t.me/...", "botUrl": "https://t.me/..."},
///   "minBuild": 1,
///   "update": {"build": 2, "url": "https://example.com/relayfast.apk",
///              "notes": "Что нового"},
///   "kill": {"enabled": false, "message": ""},
///   "notice": "Текст баннера на главном экране"
/// }
/// ```
class RemoteConfig {
  const RemoteConfig({
    this.brandName,
    this.accentHex,
    this.supportUrl,
    this.botUrl,
    this.minBuild = 0,
    this.updateBuild = 0,
    this.updateUrl,
    this.updateNotes,
    this.killEnabled = false,
    this.killMessage,
    this.notice,
  });

  static const empty = RemoteConfig();
  static const headerName = 'x-relayfast-config';

  final String? brandName;
  final String? accentHex;
  final String? supportUrl;
  final String? botUrl;

  /// Версии (build number) ниже этой работать не должны.
  final int minBuild;
  final int updateBuild;
  final String? updateUrl;
  final String? updateNotes;

  /// Аварийное отключение: приложение отключается и блокируется.
  final bool killEnabled;
  final String? killMessage;
  final String? notice;

  bool updateRequired(int currentBuild) => currentBuild < minBuild;
  bool updateAvailable(int currentBuild) => currentBuild < updateBuild;

  factory RemoteConfig.fromJson(Map<String, dynamic> j) {
    final brand = (j['brand'] as Map?)?.cast<String, dynamic>() ?? const {};
    final update = (j['update'] as Map?)?.cast<String, dynamic>() ?? const {};
    final kill = (j['kill'] as Map?)?.cast<String, dynamic>() ?? const {};
    return RemoteConfig(
      brandName: brand['name'] as String?,
      accentHex: brand['accent'] as String?,
      supportUrl: brand['supportUrl'] as String?,
      botUrl: brand['botUrl'] as String?,
      minBuild: (j['minBuild'] as num?)?.toInt() ?? 0,
      updateBuild: (update['build'] as num?)?.toInt() ?? 0,
      updateUrl: update['url'] as String?,
      updateNotes: update['notes'] as String?,
      killEnabled: kill['enabled'] == true,
      killMessage: kill['message'] as String?,
      notice: j['notice'] as String?,
    );
  }

  /// Возвращает null, если заголовка нет или он не разобрался.
  static RemoteConfig? fromHeader(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final text = raw.startsWith('base64:')
          ? utf8.decode(base64.decode(base64.normalize(raw.substring(7))))
          : raw;
      final j = jsonDecode(text);
      if (j is Map<String, dynamic>) return RemoteConfig.fromJson(j);
    } catch (_) {}
    return null;
  }

  Map<String, dynamic> toJson() => {
        'brand': {
          'name': brandName,
          'accent': accentHex,
          'supportUrl': supportUrl,
          'botUrl': botUrl,
        },
        'minBuild': minBuild,
        'update': {'build': updateBuild, 'url': updateUrl, 'notes': updateNotes},
        'kill': {'enabled': killEnabled, 'message': killMessage},
        'notice': notice,
      };
}

String formatBytes(int b) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  double v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}
