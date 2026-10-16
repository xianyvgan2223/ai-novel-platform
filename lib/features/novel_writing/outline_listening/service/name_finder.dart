import 'dart:convert';

/// 一个「可能的人名 / 地名 / 组织名」候选。
class OutlineNameCandidate {
  /// 候选原文
  final String text;

  /// 在大纲里出现的次数
  final int count;

  /// 归类（人名 / 地名 / 其它专名），用于列表上分组显示
  final OutlineNameKind kind;

  /// 来源说明（为什么被挑出来），列表上给用户一个判断依据
  final String reason;

  const OutlineNameCandidate({
    required this.text,
    required this.count,
    required this.kind,
    required this.reason,
  });

  @override
  bool operator ==(Object other) =>
      other is OutlineNameCandidate && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// 候选归类
enum OutlineNameKind {
  person('人名'),
  place('地名'),
  other('其它专名');

  final String label;

  const OutlineNameKind(this.label);
}

/// 从大纲正文里**离线**挑出人名 / 地名候选。
///
/// 不调用 AI：改名是高频操作（写到一半想换名字很常见），每次都等模型返回太慢，
/// 而且改名与朗读都不依赖网络。这里用可解释的规则挑：
///
/// 1. **人物设定里的名字**（[protagonist] 与 [characterNames]）直接进来——
///    作者填过的主角名与人物档案，一定是要改的第一候选，且无视出现次数；
/// 2. **姓氏开头的人名**：百家姓里常见的单姓 + 1~2 个字，出现 2 次以上；
/// 3. **地名 / 组织名**：以「城、山、河、派、宗、门、殿、宫……」等结尾的
///    2~6 字词组，出现 2 次以上。
///
/// 挑出来的只是**候选**：面板上可以逐条删、也可以手填任何词，最终改什么由用户定。
/// 宁可多挑几个让用户删，也别漏掉——漏了用户就得手打。
///
/// 为什么还要「清理首尾」：中文没有词边界，正则只能按「字 + 后缀」这种形态去框，
/// 框出来的常常带上相邻的字（`李云飞在青阳城` 这种）。因此每个候选都要经过
/// [_clean] 把首尾的虚词（在 / 的 / 与……）剥掉，剥不掉就丢掉。
List<OutlineNameCandidate> findOutlineNameCandidates({
  required String content,
  String protagonist = '',
  List<String> characterNames = const [],
  int minCount = 2,
  int limit = 80,
}) {
  final counts = <String, int>{};
  final kinds = <String, OutlineNameKind>{};
  final reasons = <String, String>{};

  void add(String raw, OutlineNameKind kind, String reason, {int weight = 1}) {
    final text = _clean(raw);
    if (text == null) return;
    counts[text] = (counts[text] ?? 0) + weight;
    // 已有的归类不降级：人名优先于其它专名
    final prev = kinds[text];
    if (prev == null || _rank(kind) < _rank(prev)) {
      kinds[text] = kind;
      reasons[text] = reason;
    }
  }

  // 1) 设定里的名字：给足权重（权重直接加到计数上，保证它们能排到前面）
  for (final name in _splitNames(protagonist)) {
    add(name, OutlineNameKind.person, '小说设定里的主角', weight: 100);
  }
  for (final name in characterNames) {
    add(name, OutlineNameKind.person, '人物设定里的名字', weight: 100);
  }

  // 2) 正文里按规则扫
  final cjk = RegExp(r'[\u4e00-\u9fa5]');
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    for (final match in _surnameNameRe.allMatches(line)) {
      add(match.group(0)!, OutlineNameKind.person, '姓氏开头，多次出现');
    }
    for (final suffix in _placeSuffixes) {
      var at = line.indexOf(suffix);
      while (at >= 0) {
        // 从后缀往前取 1~4 个字作为名字主体：逐个字符往前退，
        // 退到句读 / 虚词 / 行首就停（这样不会跨句把相邻的词粘进来）
        for (var len = 4; len >= 1; len--) {
          final start = at - len;
          if (start < 0) continue;
          final body = line.substring(start, at);
          if (!_isNameBody(body)) continue;
          add('$body$suffix', OutlineNameKind.place, '带地名 / 门派后缀，多次出现');
          break;
        }
        at = line.indexOf(suffix, at + suffix.length);
      }
    }

    // 3) 书名号包起来的多字专名：作者自己标出来的，命中率最高
    for (final match in RegExp(r'《([^》]{2,8})》').allMatches(line)) {
      final text = match.group(1)!;
      if (cjk.hasMatch(text)) {
        add(text, OutlineNameKind.other, '书名号标出的专名', weight: 5);
      }
    }
  }

  final list = <OutlineNameCandidate>[];
  for (final entry in counts.entries) {
    final text = entry.key;
    final kind = kinds[text] ?? OutlineNameKind.other;
    final reason = reasons[text] ?? '';
    final fromSettings = reason.contains('设定');
    if (!fromSettings && entry.value < minCount) continue;
    list.add(
      OutlineNameCandidate(
        text: text,
        count: entry.value,
        kind: kind,
        reason: reason,
      ),
    );
  }

  // 去掉「明显是同一个名字的前半截」的候选：「李云飞」出现 10 次、「李云」只出现
  // 3 次时，后者多半是同一个人的截断（改它会连名带姓一起改错）；次数接近时
  // 保留（可能是两个不同的人）。
  final kept = <OutlineNameCandidate>[];
  for (final c in list) {
    final cloaked = list.any(
      (o) =>
          o.text.length == c.text.length + 1 &&
          o.text.startsWith(c.text) &&
          o.count >= c.count * 2,
    );
    if (cloaked) continue;
    kept.add(c);
  }

  kept.sort((a, b) {
    final byKind = _rank(a.kind).compareTo(_rank(b.kind));
    if (byKind != 0) return byKind;
    final byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    return b.text.length.compareTo(a.text.length);
  });
  return kept.length > limit ? kept.sublist(0, limit) : kept;
}

/// 从 AI 返回的文本里解析候选名单（容错：模型常把 JSON 包在 ```json 里，
/// 或在前面加一句寒暄）。
List<OutlineNameCandidate> parseAiNameCandidates(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  final start = text.indexOf('[');
  final end = text.lastIndexOf(']');
  if (start < 0 || end <= start) return const [];
  try {
    final decoded = jsonDecode(text.substring(start, end + 1));
    if (decoded is! List) return const [];
    final out = <OutlineNameCandidate>[];
    final seen = <String>{};
    for (final item in decoded) {
      String name = '';
      String type = '';
      if (item is String) {
        name = item;
      } else if (item is Map) {
        name = (item['name'] ?? item['名称'] ?? '').toString();
        type = (item['type'] ?? item['类型'] ?? '').toString();
      }
      final clean = name.trim();
      if (clean.length < 2 || clean.length > 8) continue;
      if (!seen.add(clean)) continue;
      out.add(
        OutlineNameCandidate(
          text: clean,
          count: 1,
          kind: _kindOf(type),
          reason: 'AI 识别',
        ),
      );
    }
    return out;
  } catch (_) {
    return const [];
  }
}

OutlineNameKind _kindOf(String type) {
  final t = type.trim();
  if (t.contains('人') || t.toLowerCase().contains('person')) {
    return OutlineNameKind.person;
  }
  if (t.contains('地') ||
      t.contains('组织') ||
      t.contains('门派') ||
      t.toLowerCase().contains('place')) {
    return OutlineNameKind.place;
  }
  return OutlineNameKind.other;
}

int _rank(OutlineNameKind kind) => switch (kind) {
  OutlineNameKind.person => 0,
  OutlineNameKind.place => 1,
  OutlineNameKind.other => 2,
};

/// 剥掉候选首尾的虚词；剥完长度不足 2 字、或是纯粹的结构词时返回 null（丢弃）。
///
/// 为什么必须做这一步：正则只能按形态框，框出来的常带着相邻的字
/// （`果李云飞在`、`云飞在青阳`），不清理就会把「在」「的」这类字也当成名字的一部分
/// 塞给用户，改名时反而会改坏正文。
String? _clean(String raw) {
  var text = raw.trim();
  // 首尾的虚词与标点最多各剥两层
  for (var i = 0; i < 2; i++) {
    if (text.length > 2 && _functionWords.contains(text[0])) {
      text = text.substring(1);
    }
    if (text.length > 2 && _functionWords.contains(text[text.length - 1])) {
      text = text.substring(0, text.length - 1);
    }
  }
  if (text.length < 2 || text.length > 8) return null;
  if (_stopWords.contains(text)) return null;
  // 还夹着虚词说明这不是一个名字（如 `云飞在青`）
  if (text.split('').any(_functionWords.contains)) return null;
  return text;
}

/// 名字主体是否干净（用于「后缀 + 往前取 N 字」这条扫描路径）
bool _isNameBody(String body) {
  if (body.isEmpty || body.length > 4) return false;
  return !body.split('').any(_functionWords.contains);
}

/// 人名：常见单姓 + 1~2 个汉字
final RegExp _surnameNameRe = RegExp('[$_surnames][\u4e00-\u9fa5]{1,2}');

/// 地名 / 组织 / 门派后缀（**多字的排在前面**，扫描时先长后短，
/// 免得「青云学院」被当成「云学院」）
const List<String> _placeSuffixes = [
  '学院', '大学', '公司', '集团',
  '城', '山', '河', '江', '湖', '海', '川', '谷', '林', '原', '洲', '岛',
  '村', '镇', '县', '州', '府', '郡', '国', '界', '域', '派', '宗', '门',
  '殿', '宫', '阁', '楼', '院', '堂', '寺', '观', '塔', '会', '帮', '族',
  '家', '军', '盟', '教', '社', '团', '组',
];

/// 常用单姓（百家姓里最常用的一批）
const String _surnames =
    '赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜'
    '戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳酆鲍史唐'
    '费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄'
    '和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁'
    '杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍'
    '虞万支柯昝管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚'
    '程嵇邢滑裴陆荣翁荀羊於惠甄曲家封芮羿储靳汲邴糜松井段富巫乌焦巴弓'
    '牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭历戎祖武符刘景詹束龙'
    '叶幸司韶郜黎蓟薄印宿白怀蒲邰从鄂索咸籍赖卓蔺屠蒙池乔阴胥能苍双'
    '闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍郤璩桑桂濮牛寿通边扈燕冀郏浦尚农'
    '温别庄晏柴瞿阎充慕连茹习宦艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘'
    '匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空'
    '曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公';

/// 句子里的虚词 / 代词 / 连词：出现在候选里就说明这个候选不干净。
///
/// 只用**几乎不可能出现在人名地名里**的字，宁可漏掉几个脏候选
/// （用户可以手填），也不要把它们混进替换表（改错正文的代价更大）。
const Set<String> _functionWords = {
  '在', '的', '了', '和', '与', '及', '是', '着', '把', '被', '从', '对',
  '向', '让', '就', '都', '也', '还', '又', '只', '很', '更', '不', '没',
  '无', '要', '会', '能', '可', '我', '你', '他', '她', '它', '们',
  '这', '那', '谁', '什', '怎', '为', '因', '所', '但', '而', '且', '或',
  '如', '若', '于', '由', '至', '到', '给', '跟', '同', '并', '却', '才',
  '再', '已', '将', '当', '？', '！', '。', '，', '、', '：',
  '；', '「', '」', '“', '”', '（', '）', '…', '—', '·', ' ', '\t',
};

/// 常见结构词：它们会和姓氏或后缀拼出假候选，直接排除
const Set<String> _stopWords = {
  '他们', '她们', '我们', '你们', '自己', '众人', '所有', '一切', '之后', '之前',
  '现在', '已经', '因为', '所以', '但是', '然后', '突然', '终于', '只有', '如果',
  '这个', '那个', '这里', '那里', '一个', '什么', '怎么', '为了', '开始', '结束',
  '事件', '大事件', '小事件', '概要', '标题', '正文', '章节', '内容', '主角',
  '第一', '第二', '第三', '第四', '第五', '最后', '此时', '同时', '于是', '并且',
  '得到', '发现', '决定', '准备', '继续', '无法', '不能', '成为', '以及', '可是',
  '而且', '不过', '由于', '随着', '通过', '面对', '看着', '听着', '想到', '对方',
  '一起', '一样', '一定', '有些', '许多', '很多', '多少', '几个', '两个', '三个',
  '事情', '时间', '地方', '东西', '世界', '全部', '整个', '竟然', '果然',
};

/// 人物设定文本里抠出名字：支持「张三、李四 / 张三，李四 / 张三 李四」等写法，
/// 以及带说明的「张三（主角）」。
List<String> _splitNames(String raw) => raw
    .split(RegExp(r'[、,，;；/\s\n]+'))
    .map((s) => s.replaceAll(RegExp(r'[（(].*$'), '').trim())
    .where((s) => s.length >= 2 && s.length <= 8)
    .toList();
