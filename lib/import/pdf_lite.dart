import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;

/// Минимальный читатель PDF — ровно столько, сколько нужно, чтобы вытащить из отчёта текст,
/// векторные окружности и положение картинок. Умеет только классическую таблицу xref и потоки
/// FlateDecode (так пишут отчёты, собранные Qt); всё остальное — [PdfLiteException], а не попытка
/// угадать. Ничего не исполняет: PDF для нас — данные.
class PdfLiteException implements Exception {
  final String message;
  const PdfLiteException(this.message);
  @override
  String toString() => message;
}

class PdfName {
  final String name;
  const PdfName(this.name);
  @override
  String toString() => '/$name';
}

class PdfRef {
  final int num;
  final int gen;
  const PdfRef(this.num, this.gen);
}

class PdfString {
  final Uint8List bytes;
  const PdfString(this.bytes);

  String get text {
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final units = <int>[for (var i = 2; i + 1 < bytes.length; i += 2) (bytes[i] << 8) | bytes[i + 1]];
      return String.fromCharCodes(units);
    }
    return latin1.decode(bytes, allowInvalid: true);
  }
}

class PdfStream {
  final Map<String, dynamic> dict;
  final Uint8List raw;
  const PdfStream(this.dict, this.raw);
}

class _Op {
  final String s;
  const _Op(this.s);
}

class _Eof {
  const _Eof();
}

const _eof = _Eof();

class _Lexer {
  final Uint8List b;
  int p;
  final bool refs;
  int _depth = 0;
  _Lexer(this.b, {this.p = 0, this.refs = false});

  static bool _ws(int c) => c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 0;
  static bool _delim(int c) => c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25;
  static bool _digit(int c) => c >= 0x30 && c <= 0x39;

  void skipWs() {
    while (p < b.length) {
      final c = b[p];
      if (_ws(c)) {
        p++;
      } else if (c == 0x25) {
        while (p < b.length && b[p] != 10 && b[p] != 13) {
          p++;
        }
      } else {
        break;
      }
    }
  }

  /// Следующий токен: число, [PdfName], [PdfString], [PdfRef] (если [refs]), List, Map, bool, null,
  /// [_Op] (оператор / ключевое слово) или [_eof].
  Object? next() {
    skipWs();
    if (p >= b.length) return _eof;
    final c = b[p];
    switch (c) {
      case 0x2F:
        return _name();
      case 0x28:
        return _literal();
      case 0x3C:
        if (p + 1 < b.length && b[p + 1] == 0x3C) {
          p += 2;
          return _dict();
        }
        return _hex();
      case 0x5B:
        p++;
        return _array();
      case 0x5D:
        p++;
        return const _Op(']');
      case 0x3E:
        if (p + 1 < b.length && b[p + 1] == 0x3E) {
          p += 2;
          return const _Op('>>');
        }
        p++;
        return const _Op('>');
      case 0x29:
      case 0x7B:
      case 0x7D:
        p++;
        return _Op(String.fromCharCode(c));
    }
    final start = p;
    while (p < b.length && !_ws(b[p]) && !_delim(b[p])) {
      p++;
    }
    final tok = latin1.decode(b.sublist(start, p));
    final n = num.tryParse(tok);
    if (n != null) {
      if (refs && n is int && n >= 0) return _maybeRef(n);
      return n;
    }
    switch (tok) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
        return null;
    }
    return _Op(tok);
  }

  Object _maybeRef(int n) {
    var q = p;
    while (q < b.length && _ws(b[q])) {
      q++;
    }
    final s = q;
    while (q < b.length && _digit(b[q])) {
      q++;
    }
    if (q == s || q - s > 6) return n;
    final gen = int.parse(latin1.decode(b.sublist(s, q)));
    while (q < b.length && _ws(b[q])) {
      q++;
    }
    if (q < b.length && b[q] == 0x52 && (q + 1 >= b.length || _ws(b[q + 1]) || _delim(b[q + 1]))) {
      p = q + 1;
      return PdfRef(n, gen);
    }
    return n;
  }

  PdfName _name() {
    p++;
    final out = StringBuffer();
    while (p < b.length && !_ws(b[p]) && !_delim(b[p])) {
      var c = b[p];
      if (c == 0x23 && p + 2 < b.length) {
        final v = int.tryParse(latin1.decode(b.sublist(p + 1, p + 3)), radix: 16);
        if (v != null) {
          c = v;
          p += 2;
        }
      }
      out.writeCharCode(c);
      p++;
    }
    return PdfName(out.toString());
  }

  PdfString _literal() {
    p++;
    final out = <int>[];
    var depth = 1;
    while (p < b.length) {
      final c = b[p++];
      if (c == 0x5C) {
        if (p >= b.length) break;
        final e = b[p++];
        switch (e) {
          case 0x6E:
            out.add(10);
          case 0x72:
            out.add(13);
          case 0x74:
            out.add(9);
          case 0x62:
            out.add(8);
          case 0x66:
            out.add(12);
          case 10:
            break;
          case 13:
            if (p < b.length && b[p] == 10) p++;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var v = e - 0x30;
              for (var i = 0; i < 2 && p < b.length && b[p] >= 0x30 && b[p] <= 0x37; i++) {
                v = v * 8 + (b[p++] - 0x30);
              }
              out.add(v & 0xFF);
            } else {
              out.add(e);
            }
        }
      } else if (c == 0x28) {
        depth++;
        out.add(c);
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        out.add(c);
      } else {
        out.add(c);
      }
      if (out.length > 4 << 20) throw const PdfLiteException('строка слишком длинная');
    }
    return PdfString(Uint8List.fromList(out));
  }

  PdfString _hex() {
    p++;
    final digits = <int>[];
    while (p < b.length && b[p] != 0x3E) {
      final c = b[p++];
      final v = c >= 0x30 && c <= 0x39
          ? c - 0x30
          : (c >= 0x41 && c <= 0x46)
              ? c - 0x41 + 10
              : (c >= 0x61 && c <= 0x66)
                  ? c - 0x61 + 10
                  : -1;
      if (v >= 0) digits.add(v);
      if (digits.length > 8 << 20) throw const PdfLiteException('строка слишком длинная');
    }
    if (p < b.length) p++;
    if (digits.length.isOdd) digits.add(0);
    return PdfString(Uint8List.fromList([for (var i = 0; i < digits.length; i += 2) (digits[i] << 4) | digits[i + 1]]));
  }

  List<Object?> _array() {
    if (++_depth > 40) throw const PdfLiteException('слишком глубокая вложенность');
    final out = <Object?>[];
    while (true) {
      final t = next();
      if (t is _Eof) break;
      if (t is _Op && t.s == ']') break;
      out.add(t);
      if (out.length > 2000000) throw const PdfLiteException('массив слишком большой');
    }
    _depth--;
    return out;
  }

  Map<String, dynamic> _dict() {
    if (++_depth > 40) throw const PdfLiteException('слишком глубокая вложенность');
    final out = <String, dynamic>{};
    while (true) {
      final k = next();
      if (k is _Eof) break;
      if (k is _Op && k.s == '>>') break;
      if (k is! PdfName) continue;
      final v = next();
      if (v is _Op && v.s == '>>') {
        out[k.name] = null;
        break;
      }
      out[k.name] = v is _Op ? null : v;
    }
    _depth--;
    return out;
  }
}

/// Страница: словарь, ресурсы (с учётом наследования) и размер.
class PdfLitePage {
  final Map<String, dynamic> dict;
  final Map<String, dynamic> resources;
  final double width;
  final double height;
  const PdfLitePage(this.dict, this.resources, this.width, this.height);
}

class PdfTextBlock {
  /// Текст блока (слова разделены пробелом там, где в PDF зазор).
  final String text;

  /// Начало первого знака в пользовательских координатах PDF (y вверх).
  final double x;
  final double y;
  const PdfTextBlock(this.text, this.x, this.y);
}

class PdfPathShape {
  final double x0, y0, x1, y1;
  final bool fill;
  final bool stroke;
  final List<double>? fillColor;
  const PdfPathShape(this.x0, this.y0, this.x1, this.y1, this.fill, this.stroke, this.fillColor);
  double get width => x1 - x0;
  double get height => y1 - y0;
}

class PdfImagePlace {
  final PdfRef? ref;
  final double x0, y0, x1, y1;
  const PdfImagePlace(this.ref, this.x0, this.y0, this.x1, this.y1);
}

class PdfPageContent {
  final double width;
  final double height;
  final List<PdfTextBlock> blocks;
  final List<PdfPathShape> paths;
  final List<PdfImagePlace> images;
  const PdfPageContent(this.width, this.height, this.blocks, this.paths, this.images);
}

class _Font {
  final Map<int, String> toUni;
  final Map<int, double> widths;
  final double dw;
  final bool twoByte;
  const _Font(this.toUni, this.widths, this.dw, this.twoByte);
}

class PdfLiteDoc {
  static const maxBytes = 40 << 20;
  static const maxPages = 400;

  final Uint8List bytes;
  final Map<int, int> _offsets = {};
  final Map<int, Object?> _cache = {};
  Map<String, dynamic> trailer = {};

  PdfLiteDoc._(this.bytes);

  static PdfLiteDoc open(Uint8List bytes) {
    if (bytes.length < 200 || bytes.length > maxBytes) throw const PdfLiteException('файл не подходит по размеру');
    final head = latin1.decode(bytes.sublist(0, math.min(1024, bytes.length)), allowInvalid: true);
    if (!head.contains('%PDF-')) throw const PdfLiteException('это не PDF');
    final doc = PdfLiteDoc._(bytes);
    doc._readXref();
    if (doc.trailer['Root'] == null) throw const PdfLiteException('нет корня документа');
    return doc;
  }

  void _readXref() {
    final tailStart = math.max(0, bytes.length - 2048);
    final tail = latin1.decode(bytes.sublist(tailStart), allowInvalid: true);
    final i = tail.lastIndexOf('startxref');
    if (i < 0) throw const PdfLiteException('нет startxref');
    final lx = _Lexer(bytes, p: tailStart + i + 9);
    final first = lx.next();
    if (first is! int) throw const PdfLiteException('битый startxref');
    var off = first;
    final seen = <int>{};
    var guard = 0;
    while (guard++ < 30) {
      if (off < 0 || off >= bytes.length || !seen.add(off)) break;
      final l = _Lexer(bytes, p: off, refs: true);
      final kw = l.next();
      if (kw is! _Op || kw.s != 'xref') throw const PdfLiteException('таблица ссылок не классическая (не поддерживается)');
      while (true) {
        final t = l.next();
        if (t is _Op && t.s == 'trailer') break;
        if (t is! int) throw const PdfLiteException('битая таблица ссылок');
        final count = l.next();
        if (count is! int || count < 0 || count > 500000) throw const PdfLiteException('битая таблица ссылок');
        for (var k = 0; k < count; k++) {
          final o = l.next();
          final g = l.next();
          final ty = l.next();
          if (o is! int || g is! int || ty is! _Op) throw const PdfLiteException('битая таблица ссылок');
          if (ty.s == 'n') _offsets.putIfAbsent(t + k, () => o);
        }
      }
      final tr = l.next();
      if (tr is! Map<String, dynamic>) throw const PdfLiteException('битый trailer');
      for (final e in tr.entries) {
        trailer.putIfAbsent(e.key, () => e.value);
      }
      final prev = tr['Prev'];
      if (prev is int) {
        off = prev;
      } else {
        break;
      }
    }
  }

  Object? object(int n) {
    if (_cache.containsKey(n)) return _cache[n];
    final off = _offsets[n];
    if (off == null || off < 0 || off >= bytes.length) return null;
    final l = _Lexer(bytes, p: off, refs: true);
    final a = l.next();
    final g = l.next();
    final kw = l.next();
    if (a != n || g is! int || kw is! _Op || kw.s != 'obj') throw const PdfLiteException('битый объект');
    final v = l.next();
    Object? out = v is _Op ? null : v;
    if (v is Map<String, dynamic>) {
      final save = l.p;
      final t = l.next();
      if (t is _Op && t.s == 'stream') {
        var p = l.p;
        if (p < bytes.length && bytes[p] == 13) p++;
        if (p < bytes.length && bytes[p] == 10) p++;
        final len = resolve(v['Length']);
        var end = -1;
        if (len is int && len >= 0 && p + len <= bytes.length) {
          var q = p + len;
          while (q < bytes.length && _Lexer._ws(bytes[q])) {
            q++;
          }
          if (q + 9 <= bytes.length && latin1.decode(bytes.sublist(q, q + 9)) == 'endstream') end = p + len;
        }
        if (end < 0) {
          final marker = 'endstream'.codeUnits;
          var q = p;
          outer:
          while (q + marker.length <= bytes.length) {
            for (var k = 0; k < marker.length; k++) {
              if (bytes[q + k] != marker[k]) {
                q++;
                continue outer;
              }
            }
            end = q;
            break;
          }
          if (end < 0) throw const PdfLiteException('поток без конца');
        }
        out = PdfStream(v, Uint8List.sublistView(bytes, p, end));
      } else {
        l.p = save;
      }
    }
    _cache[n] = out;
    return out;
  }

  Object? resolve(Object? o) {
    var d = 0;
    while (o is PdfRef) {
      if (++d > 20) throw const PdfLiteException('цикл ссылок');
      o = object(o.num);
    }
    return o;
  }

  Map<String, dynamic> dictOf(Object? o) {
    final r = resolve(o);
    if (r is Map<String, dynamic>) return r;
    if (r is PdfStream) return r.dict;
    return const {};
  }

  List<Object?> listOf(Object? o) {
    final r = resolve(o);
    return r is List<Object?> ? r : const [];
  }

  /// Метаданные документа (Info): Creator, Producer.
  Map<String, String> info() {
    final d = dictOf(trailer['Info']);
    final out = <String, String>{};
    for (final k in ['Creator', 'Producer', 'Title']) {
      final v = resolve(d[k]);
      if (v is PdfString) out[k] = v.text;
    }
    return out;
  }

  /// Распаковать поток (только FlateDecode или без сжатия).
  Uint8List streamData(Object? o, {int maxCompressed = 4 << 20, int maxOut = 64 << 20}) {
    final s = resolve(o);
    if (s is! PdfStream) throw const PdfLiteException('ожидался поток');
    if (s.raw.length > maxCompressed) throw const PdfLiteException('поток слишком большой');
    final f = resolve(s.dict['Filter']);
    final names = <String>[
      if (f is PdfName) f.name,
      if (f is List<Object?>)
        for (final x in f)
          if (resolve(x) is PdfName) (resolve(x) as PdfName).name,
    ];
    final parms = resolve(s.dict['DecodeParms']);
    if (parms is Map<String, dynamic> && (resolve(parms['Predictor']) as num? ?? 1) > 1) {
      throw const PdfLiteException('предиктор потока не поддерживается');
    }
    var data = s.raw;
    for (final n in names) {
      if (n == 'FlateDecode' || n == 'Fl') {
        try {
          data = const ZLibDecoder().decodeBytes(data);
        } catch (_) {
          throw const PdfLiteException('не удалось распаковать поток');
        }
        if (data.length > maxOut) throw const PdfLiteException('поток слишком велик после распаковки');
      } else {
        throw PdfLiteException('фильтр $n не поддерживается');
      }
    }
    return data;
  }

  List<PdfLitePage> pages() {
    final root = dictOf(trailer['Root']);
    final out = <PdfLitePage>[];
    void walk(Object? node, Map<String, dynamic> inheritedRes, List<double> inheritedBox, int depth) {
      if (depth > 12 || out.length > maxPages) return;
      final d = dictOf(node);
      var res = inheritedRes;
      if (d['Resources'] != null) res = dictOf(d['Resources']);
      var box = inheritedBox;
      final mb = listOf(d['MediaBox']);
      if (mb.length == 4 && mb.every((e) => resolve(e) is num)) {
        box = [for (final e in mb) (resolve(e) as num).toDouble()];
      }
      final kids = d['Kids'];
      if (kids != null) {
        for (final k in listOf(kids)) {
          walk(k, res, box, depth + 1);
          if (out.length > maxPages) return;
        }
      } else {
        out.add(PdfLitePage(d, res, (box[2] - box[0]).abs(), (box[3] - box[1]).abs()));
      }
    }

    walk(root['Pages'], const {}, const [0, 0, 595, 842], 0);
    if (out.length > maxPages) throw const PdfLiteException('слишком много страниц');
    return out;
  }

  // ---------- шрифты ----------

  final Map<int, _Font> _fonts = {};

  _Font? _font(Object? ref) {
    if (ref is PdfRef && _fonts.containsKey(ref.num)) return _fonts[ref.num];
    final d = dictOf(ref);
    if (d.isEmpty) return null;
    final toUni = <int, String>{};
    final tu = resolve(d['ToUnicode']);
    if (tu is PdfStream) {
      try {
        _parseCMap(streamData(tu, maxCompressed: 1 << 20), toUni);
      } catch (_) {}
    }
    final widths = <int, double>{};
    var dw = 1000.0;
    var twoByte = false;
    final sub = resolve(d['Subtype']);
    if (sub is PdfName && sub.name == 'Type0') {
      twoByte = true;
      final desc = listOf(d['DescendantFonts']);
      if (desc.isNotEmpty) {
        final cd = dictOf(desc.first);
        final x = resolve(cd['DW']);
        if (x is num) dw = x.toDouble();
        final w = listOf(cd['W']);
        var i = 0;
        while (i < w.length) {
          final c = resolve(w[i]);
          if (c is! num) break;
          if (i + 1 >= w.length) break;
          final nx = resolve(w[i + 1]);
          if (nx is List<Object?>) {
            for (var k = 0; k < nx.length; k++) {
              final v = resolve(nx[k]);
              if (v is num) widths[c.toInt() + k] = v.toDouble();
            }
            i += 2;
          } else if (nx is num && i + 2 < w.length) {
            final v = resolve(w[i + 2]);
            if (v is num && nx.toInt() - c.toInt() < 70000) {
              for (var k = c.toInt(); k <= nx.toInt(); k++) {
                widths[k] = v.toDouble();
              }
            }
            i += 3;
          } else {
            break;
          }
        }
      }
    } else {
      final first = resolve(d['FirstChar']);
      final ws = listOf(d['Widths']);
      if (first is num) {
        for (var k = 0; k < ws.length; k++) {
          final v = resolve(ws[k]);
          if (v is num) widths[first.toInt() + k] = v.toDouble();
        }
      }
    }
    final f = _Font(toUni, widths, dw, twoByte);
    if (ref is PdfRef) _fonts[ref.num] = f;
    return f;
  }

  static String _utf16be(Uint8List b) {
    final units = <int>[for (var i = 0; i + 1 < b.length; i += 2) (b[i] << 8) | b[i + 1]];
    return String.fromCharCodes(units);
  }

  static void _parseCMap(Uint8List data, Map<int, String> out) {
    final l = _Lexer(data);
    int code(Object? t) {
      if (t is! PdfString) return -1;
      var v = 0;
      for (final x in t.bytes) {
        v = (v << 8) | x;
      }
      return v;
    }

    var tokens = 0;
    while (true) {
      final t = l.next();
      if (t is _Eof) break;
      if (++tokens > 400000) break;
      if (t is! _Op) continue;
      if (t.s == 'beginbfchar') {
        while (true) {
          final a = l.next();
          if (a is _Eof || (a is _Op && a.s == 'endbfchar')) break;
          final b = l.next();
          if (a is PdfString && b is PdfString) out[code(a)] = _utf16be(b.bytes);
        }
      } else if (t.s == 'beginbfrange') {
        while (true) {
          final a = l.next();
          if (a is _Eof || (a is _Op && a.s == 'endbfrange')) break;
          final b = l.next();
          final c = l.next();
          final lo = code(a), hi = code(b);
          if (lo < 0 || hi < lo || hi - lo > 70000) continue;
          if (c is List<Object?>) {
            for (var k = 0; k < c.length && lo + k <= hi; k++) {
              final e = c[k];
              if (e is PdfString) out[lo + k] = _utf16be(e.bytes);
            }
          } else if (c is PdfString && c.bytes.length >= 2) {
            final base = _utf16be(c.bytes);
            if (base.isEmpty) continue;
            final head = base.substring(0, base.length - 1);
            final last = base.codeUnitAt(base.length - 1);
            for (var k = lo; k <= hi; k++) {
              out[k] = head + String.fromCharCode(last + (k - lo));
            }
          }
        }
      }
    }
  }

  // ---------- содержимое страницы ----------

  PdfPageContent content(PdfLitePage page) {
    final cs = page.dict['Contents'];
    final parts = <Uint8List>[];
    final r = resolve(cs);
    if (r is PdfStream) {
      parts.add(streamData(r));
    } else if (r is List<Object?>) {
      for (final x in r) {
        parts.add(streamData(x));
      }
    }
    final builder = BytesBuilder(copy: false);
    for (final p in parts) {
      builder.add(p);
      builder.addByte(10);
    }
    final data = builder.toBytes();
    if (data.length > 48 << 20) throw const PdfLiteException('содержимое страницы слишком велико');

    final fontsDict = dictOf(page.resources['Font']);
    final fonts = <String, _Font>{};
    for (final e in fontsDict.entries) {
      final f = _font(e.value);
      if (f != null) fonts[e.key] = f;
    }
    final xobj = dictOf(page.resources['XObject']);
    return _Interpreter(page.width, page.height, fonts, xobj, this).run(data);
  }
}

typedef _M = List<double>;

_M _mul(_M a, _M b) => [
      a[0] * b[0] + a[1] * b[2],
      a[0] * b[1] + a[1] * b[3],
      a[2] * b[0] + a[3] * b[2],
      a[2] * b[1] + a[3] * b[3],
      a[4] * b[0] + a[5] * b[2] + b[4],
      a[4] * b[1] + a[5] * b[3] + b[5],
    ];

class _Interpreter {
  final double width, height;
  final Map<String, _Font> fonts;
  final Map<String, dynamic> xobjects;
  final PdfLiteDoc doc;
  _Interpreter(this.width, this.height, this.fonts, this.xobjects, this.doc);

  final blocks = <PdfTextBlock>[];
  final paths = <PdfPathShape>[];
  final images = <PdfImagePlace>[];

  _M ctm = [1, 0, 0, 1, 0, 0];
  List<double> fill = [0];
  final _stack = <(_M, List<double>)>[];

  // путь
  final _px = <double>[];
  final _py = <double>[];

  // текст
  _M tm = [1, 0, 0, 1, 0, 0];
  _M tlm = [1, 0, 0, 1, 0, 0];
  _Font? font;
  double fontSize = 1;
  double leading = 0;

  // сборка блока
  final StringBuffer _buf = StringBuffer();
  double? _bx, _by;
  double? _prevEndX, _prevY, _prevEm;

  void _flushBlock() {
    final t = _buf.toString().trim();
    if (t.isNotEmpty && _bx != null) blocks.add(PdfTextBlock(t, _bx!, _by!));
    _buf.clear();
    _bx = null;
    _by = null;
    _prevEndX = null;
    _prevY = null;
    _prevEm = null;
  }

  (double, double) _pt(_M m, double x, double y) => (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]);

  void _show(Uint8List s) {
    final f = font;
    if (f == null) return;
    final step = f.twoByte ? 2 : 1;
    for (var i = 0; i + step <= s.length; i += step) {
      final code = f.twoByte ? (s[i] << 8) | s[i + 1] : s[i];
      final ch = f.toUni[code] ?? (f.twoByte ? '?' : String.fromCharCode(code));
      final w = (f.widths[code] ?? f.dw) / 1000 * fontSize;
      final m = _mul(tm, ctm);
      final (x, y) = _pt(m, 0, 0);
      final (ex, _) = _pt(m, w, 0);
      final em = math.sqrt(m[0] * m[0] + m[1] * m[1]) * fontSize;
      final bad = _prevEndX != null && ((y - _prevY!).abs() > 0.3 * (_prevEm ?? em) || x < _prevEndX! - 0.5 * (_prevEm ?? em));
      if (bad) _flushBlock();
      if (_bx == null) {
        _bx = x;
        _by = y;
      } else if (x - _prevEndX! > 0.22 * (_prevEm ?? em)) {
        _buf.write(' ');
      }
      _buf.write(ch);
      _prevEndX = ex;
      _prevY = y;
      _prevEm = em;
      tm = _mul([1, 0, 0, 1, w, 0], tm);
    }
  }

  void _paint(bool doFill, bool doStroke) {
    if (_px.isNotEmpty && paths.length < 300000) {
      var x0 = _px[0], x1 = _px[0], y0 = _py[0], y1 = _py[0];
      for (var i = 1; i < _px.length; i++) {
        x0 = math.min(x0, _px[i]);
        x1 = math.max(x1, _px[i]);
        y0 = math.min(y0, _py[i]);
        y1 = math.max(y1, _py[i]);
      }
      paths.add(PdfPathShape(x0, y0, x1, y1, doFill, doStroke, doFill ? List.of(fill) : null));
    }
    _px.clear();
    _py.clear();
  }

  void _add(double x, double y) {
    final (a, b) = _pt(ctm, x, y);
    _px.add(a);
    _py.add(b);
    if (_px.length > 200000) throw const PdfLiteException('путь слишком большой');
  }

  static double _n(Object? v) => v is num ? v.toDouble() : 0;

  PdfPageContent run(Uint8List data) {
    final l = _Lexer(data);
    final st = <Object?>[];
    var ops = 0;
    while (true) {
      final t = l.next();
      if (t is _Eof) break;
      if (++ops > 4000000) throw const PdfLiteException('содержимое страницы слишком сложное');
      if (t is! _Op) {
        st.add(t);
        if (st.length > 4000) st.removeRange(0, 2000);
        continue;
      }
      final o = t.s;
      switch (o) {
        case 'q':
          if (_stack.length < 400) _stack.add((List.of(ctm), List.of(fill)));
        case 'Q':
          if (_stack.isNotEmpty) {
            final (m, f) = _stack.removeLast();
            ctm = m;
            fill = f;
          }
        case 'cm':
          if (st.length >= 6) {
            final v = st.sublist(st.length - 6).map(_n).toList();
            ctm = _mul(v, ctm);
          }
        case 'g':
        case 'rg':
        case 'k':
        case 'sc':
        case 'scn':
          final nums = [for (final e in st) if (e is num) e.toDouble()];
          if (nums.isNotEmpty) {
            if (o == 'k' || (nums.length == 4)) {
              final c = nums.sublist(nums.length - 4);
              fill = [(1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])];
            } else {
              fill = nums.length >= 3 ? nums.sublist(nums.length - 3) : [nums.last];
            }
          }
        case 'm':
          if (st.length >= 2) _add(_n(st[st.length - 2]), _n(st.last));
        case 'l':
          if (st.length >= 2) _add(_n(st[st.length - 2]), _n(st.last));
        case 'c':
          if (st.length >= 6) {
            for (var i = 6; i >= 2; i -= 2) {
              _add(_n(st[st.length - i]), _n(st[st.length - i + 1]));
            }
          }
        case 'v':
        case 'y':
          if (st.length >= 4) {
            _add(_n(st[st.length - 4]), _n(st[st.length - 3]));
            _add(_n(st[st.length - 2]), _n(st.last));
          }
        case 're':
          if (st.length >= 4) {
            final x = _n(st[st.length - 4]), y = _n(st[st.length - 3]), w = _n(st[st.length - 2]), h = _n(st.last);
            _add(x, y);
            _add(x + w, y);
            _add(x + w, y + h);
            _add(x, y + h);
          }
        case 'f':
        case 'F':
        case 'f*':
          _paint(true, false);
        case 'B':
        case 'B*':
        case 'b':
        case 'b*':
          _paint(true, true);
        case 'S':
        case 's':
          _paint(false, true);
        case 'n':
          _px.clear();
          _py.clear();
        case 'BT':
          tm = [1, 0, 0, 1, 0, 0];
          tlm = [1, 0, 0, 1, 0, 0];
          _flushBlock();
        case 'ET':
          _flushBlock();
        case 'Tf':
          if (st.length >= 2) {
            final nm = st[st.length - 2];
            if (nm is PdfName) font = fonts[nm.name];
            fontSize = _n(st.last);
          }
        case 'Tm':
          if (st.length >= 6) {
            tm = st.sublist(st.length - 6).map(_n).toList();
            tlm = List.of(tm);
          }
        case 'Td':
        case 'TD':
          if (st.length >= 2) {
            final tx = _n(st[st.length - 2]), ty = _n(st.last);
            if (o == 'TD') leading = -ty;
            tlm = _mul([1, 0, 0, 1, tx, ty], tlm);
            tm = List.of(tlm);
          }
        case 'T*':
          tlm = _mul([1, 0, 0, 1, 0, -leading], tlm);
          tm = List.of(tlm);
        case 'TL':
          if (st.isNotEmpty) leading = _n(st.last);
        case 'Tj':
          if (st.isNotEmpty && st.last is PdfString) _show((st.last as PdfString).bytes);
        case "'":
          tlm = _mul([1, 0, 0, 1, 0, -leading], tlm);
          tm = List.of(tlm);
          if (st.isNotEmpty && st.last is PdfString) _show((st.last as PdfString).bytes);
        case 'TJ':
          if (st.isNotEmpty && st.last is List<Object?>) {
            for (final e in st.last as List<Object?>) {
              if (e is PdfString) {
                _show(e.bytes);
              } else if (e is num) {
                final shift = -e.toDouble() / 1000 * fontSize;
                tm = _mul([1, 0, 0, 1, shift, 0], tm);
              }
            }
          }
        case 'Do':
          if (st.isNotEmpty && st.last is PdfName) {
            final ref = xobjects[(st.last as PdfName).name];
            final d = doc.dictOf(ref);
            final sub = doc.resolve(d['Subtype']);
            if (sub is PdfName && sub.name == 'Image' && images.length < 5000) {
              final p1 = _pt(ctm, 0, 0), p2 = _pt(ctm, 1, 0), p3 = _pt(ctm, 0, 1), p4 = _pt(ctm, 1, 1);
              final xs = [p1.$1, p2.$1, p3.$1, p4.$1], ys = [p1.$2, p2.$2, p3.$2, p4.$2];
              images.add(PdfImagePlace(ref is PdfRef ? ref : null, xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max)));
            }
          }
        case 'BI':
          // встроенная картинка: пропускаем до EI
          var q = l.p;
          var found = false;
          while (q + 2 < data.length) {
            if (data[q] == 0x45 && data[q + 1] == 0x49 && _Lexer._ws(data[q - 1 < 0 ? 0 : q - 1]) && (q + 2 >= data.length || _Lexer._ws(data[q + 2]))) {
              found = true;
              break;
            }
            q++;
          }
          if (!found) throw const PdfLiteException('встроенная картинка без конца');
          l.p = q + 2;
      }
      st.clear();
    }
    _flushBlock();
    return PdfPageContent(width, height, blocks, paths, images);
  }
}
