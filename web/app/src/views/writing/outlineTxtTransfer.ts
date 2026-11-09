/**
 * 大纲 txt 导出 / 导入的纯函数实现（不含任何 DOM 操作，方便单测与复用）。
 *
 * 行为规格见 reports/outline-txt-transfer-spec.md 第 2 节：
 * - 导出：UTF-8 + BOM 的 v2 结构化 txt（正文 + 书名 / 类型 / 主题 / 主角简介 /
 *   世界观 / 伏笔清单 / 人物档案）、文件名《书名》大纲.txt、非法字符替换为 `_`；
 * - 导入：按 BOM 识别 UTF-8 / UTF-16LE / UTF-16BE，其余按 UTF-8 严格解码；
 *   v2 文件头识别结构化格式并把设定 / 人物档案还原成字段；没有 v2 文件头的
 *   旧版纯正文 txt 仍按纯正文兼容导入；
 * - 标题推导：v2 书名章节 > 正文书名行 > 文件名 > 「未命名大纲」；
 * - 事件解析：网页端最小实现，与手机端「大纲编辑」的常见写法对齐（不做重编号）。
 */

/** 解码失败时的统一提示（与手机端一致） */
export const DECODE_ERROR_MESSAGE = '文件不是 UTF-8 / UTF-16 编码，请用记事本另存为 UTF-8 后再导入';

/** 解析出来的一条事件（可直接映射成 outline_chapters 的一行） */
export interface ParsedOutlineEvent {
  /** 从 1 连续递增，大事件 / 小事件都占号（与手机端 OutlineChapter.eventIndex 一致） */
  eventIndex: number;
  eventType: 'major' | 'minor';
  eventTitle: string;
  /** 事件行之后、下一个边界之前的非空行，保留换行与原缩进 */
  eventSummary: string;
}

/** UTF-8 严格解码（失败时抛出带统一提示的 Error） */
function decodeUtf8Strict(bytes: Uint8Array): string {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    throw new Error(DECODE_ERROR_MESSAGE);
  }
}

/**
 * 按 BOM 解码大纲 txt 的字节：EF BB BF → UTF-8、FF FE → UTF-16LE、FE FF → UTF-16BE，
 * 没有 BOM 时按 UTF-8 严格解码。BOM 字节不进入结果文本。
 */
export function decodeOutlineBytes(bytes: Uint8Array): string {
  // UTF-8 BOM：EF BB BF
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return decodeUtf8Strict(bytes.subarray(3));
  }
  // UTF-16LE BOM：FF FE
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    return new TextDecoder('utf-16le').decode(bytes.subarray(2));
  }
  // UTF-16BE BOM：FE FF
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    return new TextDecoder('utf-16be').decode(bytes.subarray(2));
  }
  return decodeUtf8Strict(bytes);
}

/**
 * 导入文本规范化：去 BOM 残留、把 `\r\n` / 单独的 `\r` 统一成 `\n`、去掉首尾空白。
 * 网页端不重编号、不改写事件行（规格 2.2 第 4 条）。
 */
export function normalizeImportedOutline(raw: string): string {
  return raw.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();
}

/** 正文首行的「书名：《…》」（允许书名与冒号之间有空白） */
const BOOK_TITLE_LINE_RE = /书名\s*[:：]\s*《\s*([^》\n]+?)\s*》/;
/** 文件名末尾的「-大纲 / 大纲 / 大纲正文」 */
const FILE_NAME_SUFFIX_RE = /(?:[-－—_·]?\s*大纲正文|[-－—_·]?\s*大纲)\s*$/;

/** 从文件名推导书名：去 .txt、去末尾「-大纲 / 大纲 / 大纲正文」、去两侧《》 */
function titleFromFileName(fileName: string): string {
  const withoutExt = String(fileName ?? '').trim().replace(/\.txt$/i, '').trim();
  const withoutSuffix = withoutExt.replace(FILE_NAME_SUFFIX_RE, '').trim();
  return withoutSuffix.replace(/^《+/, '').replace(/》+$/, '').trim();
}

/**
 * 推导导入作品的标题（可编辑的初始值）：
 * 1) 正文前 3 行匹配「书名：《…》」时取书名（正文常以居中的书名行开头，前面
 *    偶尔有装饰行；与手机端一致）；
 * 2) 否则用文件名（去 .txt / 末尾「-大纲」「大纲」「大纲正文」/ 两侧《》）；
 * 3) 都拿不到时用「未命名大纲」。
 */
export function deriveOutlineTitle(content: string, fileName: string): string {
  const firstLines = content.split('\n').slice(0, 3);
  for (const line of firstLines) {
    const fromContent = BOOK_TITLE_LINE_RE.exec(line.trim());
    const contentTitle = fromContent?.[1]?.trim() ?? '';
    if (contentTitle) return contentTitle;
  }
  return titleFromFileName(fileName) || '未命名大纲';
}

/** Windows / Android 文件名非法字符 */
const ILLEGAL_FILE_NAME_CHARS = /[\\/:*?"<>|]/g;

/**
 * 导出文件名：`《书名》大纲.txt`；书名为空（或全空白）时用 `《未命名大纲》大纲.txt`
 * （与手机端保持一致，始终带书名号）。
 * 非法字符 `\ / : * ? " < > |` 替换成 `_`，并去掉首尾空白与末尾的点。
 */
export function outlineFileName(title: string): string {
  const text = String(title ?? '').trim();
  const safe = text.replace(ILLEGAL_FILE_NAME_CHARS, '_').trim().replace(/\.+$/, '').trim();
  return `《${safe || '未命名大纲'}》大纲.txt`;
}

/* ───────────────────────── 事件解析（网页端最小实现） ───────────────────────── */

/**
 * 行首修饰：markdown 标题前缀、列表符号（○ • · - * _）、强调标记、══ / == 装饰，
 * 可任意组合、可重复出现（兼容「### ○ **小事件1：标题**」「## ══ 大事件28：… ══」等写法）。
 */
const LEAD = String.raw`(?:#{1,6}\s*|[○•·\-*_]\s*|[═=＝]+\s*)*`;
/** 行尾修饰：强调标记与 ══ / == 装饰 */
const TAIL = String.raw`(?:[═=＝]+\s*|\*{1,3}\s*|_{1,3}\s*)*`;
/** 事件编号：多位数字 / 占位符 X / 带圈数字 / 中文数字，可整体省略 */
const EVENT_NUMBER = String.raw`(?:[0-9]+|[Xx]|[①②③④⑤⑥⑦⑧⑨⑩]|[一二三四五六七八九十百零]+)?`;

/** 大事件标题行：可选前缀 + 可选「══ / ==」 +「大事件N：标题」+ 可选尾部装饰 */
const MAJOR_RE = new RegExp(`^\\s*${LEAD}(?:大事件|Major|事件)\\s*${EVENT_NUMBER}\\s*[：:]\\s*(.+?)\\s*${TAIL}$`);
/** 小事件标题行：同大事件（○ / • / · 等列表符号已含在 LEAD 里） */
const MINOR_RE = new RegExp(`^\\s*${LEAD}(?:小事件|事件)\\s*${EVENT_NUMBER}\\s*[：:]\\s*(.+?)\\s*${TAIL}$`);
/** 幕标题行（如「第一幕：开端」「## 第三幕」）：只作为概要边界，不产生事件 */
const ACT_RE = new RegExp(
  `^\\s*${LEAD}(第\\s*[一二三四五六七八九十百零0-9]+\\s*幕)(\\s*[：:]?\\s*)(.*?)\\s*${TAIL}$`,
);
/** 纯装饰行：只由 ═ / = / ＝ 与空白组成 */
const DECORATION_RE = /^[═=＝\s]+$/;

type OutlineLineKind = 'major' | 'minor' | 'act' | 'decoration' | 'other';

interface ClassifiedLine {
  kind: OutlineLineKind;
  /** 大事件 / 小事件的标题；其余类型为空串 */
  title: string;
  /** 幕标题的完整标签（如「第一幕：开端」），非幕行为空 */
  actLabel?: string;
}

/** 去掉标题两端残留的强调 / 装饰标记：**归来的伤口** → 归来的伤口 */
function cleanEventTitle(raw: string): string {
  return raw.replace(/^[\s═=＝*_]+/, '').replace(/[\s═=＝*_]+$/, '').trim();
}

/**
 * 识别一行大纲。判定顺序固定：大事件 → 小事件 → 幕 → 装饰 → 其它，
 * 与手机端 outline_event_syntax.dart 的 classifyOutlineLine 保持一致。
 */
function classifyOutlineLine(raw: string): ClassifiedLine {
  const trimmed = raw.trim();
  if (!trimmed) return { kind: 'other', title: '' };

  const major = MAJOR_RE.exec(trimmed);
  if (major) {
    const title = cleanEventTitle(major[1] ?? '');
    // 标题为空的行（如断行的「大事件1：」）不算事件，避免产生无名事件
    if (title) return { kind: 'major', title };
  }

  const minor = MINOR_RE.exec(trimmed);
  if (minor) {
    const title = cleanEventTitle(minor[1] ?? '');
    if (title) return { kind: 'minor', title };
  }

  const act = ACT_RE.exec(trimmed);
  if (act) {
    const name = act[1] ?? '';
    const rawSep = act[2] ?? '';
    const tail = (act[3] ?? '').trim();
    const sep = rawSep.includes('：') || rawSep.includes(':') ? '：' : rawSep ? ' ' : '';
    return { kind: 'act', title: '', actLabel: tail ? `${name}${sep}${tail}` : name };
  }
  if (DECORATION_RE.test(trimmed)) return { kind: 'decoration', title: '' };
  return { kind: 'other', title: '' };
}

/**
 * 从大纲正文解析事件（网页端最小实现，规格 2.3）：
 * - 大事件 / 小事件标题行产生事件，event_index 从 1 连续递增；
 * - 幕标题与纯装饰行是边界：不产生事件，也不并入概要；
 * - 概要 = 事件行之后到下一个边界之间的非空行，每行去掉首尾空白后按换行拼接
 *   （与手机端 `parseOutlineEvents` 的 `trim()` 一致，两端导入同一份 txt
 *   得到逐字相同的概要）；
 * - 一行都识别不出来时返回空数组（调用方仍导入正文，只是没有章节行）。
 */
export function parseOutlineEvents(content: string): ParsedOutlineEvent[] {
  const events: ParsedOutlineEvent[] = [];

  for (const raw of content.split('\n')) {
    const line = classifyOutlineLine(raw);

    if (line.kind === 'major' || line.kind === 'minor') {
      events.push({
        eventIndex: events.length + 1,
        eventType: line.kind,
        eventTitle: line.title,
        eventSummary: '',
      });
      continue;
    }

    // 幕标题与纯装饰行：边界，既不产生事件也不并入概要
    if (line.kind === 'act' || line.kind === 'decoration') continue;

    // 概要行：去掉首尾空白（与手机端一致），空行跳过
    const summaryLine = raw.trim();
    if (!summaryLine) continue;
    const last = events[events.length - 1];
    if (!last) continue; // 第一个事件之前的正文不属于任何事件
    last.eventSummary = last.eventSummary ? `${last.eventSummary}\n${summaryLine}` : summaryLine;
  }

  return events;
}

/* ───────────────── 事件 / 幕标题规范化（导出前重新编号，与手机端一致） ───────────────── */

/** 标题里嵌套的「大事件N：」/「小事件N：」前缀（生成侧回显框架时常带出来） */
const NESTED_EVENT_PREFIX_RE = new RegExp(
  `^${LEAD}(?:大事件|小事件|Major|事件)\\s*(?:[0-9]+|[Xx]|[①②③④⑤⑥⑦⑧⑨⑩]|[一二三四五六七八九十百零]+)\\s*[：:]\\s*`,
);

/** 去掉标题里嵌套的事件前缀（最多剥 3 层；前缀必须带编号，避免误伤「事件：xxx」） */
export function stripNestedEventPrefix(title: string): string {
  let text = title.trim();
  for (let i = 0; i < 3; i++) {
    const match = NESTED_EVENT_PREFIX_RE.exec(text);
    if (!match) break;
    const rest = text.slice(match[0].length).trim();
    if (!rest) break;
    text = rest;
  }
  return text;
}

/** 规范的大事件标题行（与手机端 formatMajorHeader 完全一致） */
function formatMajorHeader(index: number, title: string): string {
  return `══ 大事件${index}：${stripNestedEventPrefix(title)} ══`;
}

/** 规范的小事件标题行（与手机端 formatMinorHeader 完全一致） */
function formatMinorHeader(index: number, title: string): string {
  return `○ 小事件${index}：${stripNestedEventPrefix(title)}`;
}

/**
 * 把大纲正文里的事件 / 幕标题行统一成规范写法并**重新编号**：
 * - 大事件：全篇连续序号，`══ 大事件N：标题 ══`；
 * - 小事件：在每个大事件内部从 1 重新开始，`○ 小事件N：标题`；
 * - 幕标题：`══ 第X幕：名称 ══`。
 *
 * 只重写被识别为事件 / 幕标题的行，概要与其他正文逐字节保留；
 * 一行事件都识别不到时原样返回；对已规范化的文本再执行一次结果相同（幂等）。
 * 规则与手机端 `outline_event_syntax.dart` 的 `normalizeOutlineText` 保持一致。
 */
export function normalizeOutlineText(content: string): string {
  const lines = String(content ?? '').split('\n');
  const out: string[] = [];
  let majorSeq = 0;
  let minorSeq = 0;
  let hasEvent = false;
  let changed = false;

  for (const raw of lines) {
    const line = classifyOutlineLine(raw);
    if (line.kind === 'major') {
      hasEvent = true;
      majorSeq++;
      minorSeq = 0;
      const canonical = formatMajorHeader(majorSeq, line.title);
      if (raw !== canonical) changed = true;
      out.push(canonical);
      continue;
    }
    if (line.kind === 'minor') {
      hasEvent = true;
      minorSeq++;
      const canonical = formatMinorHeader(minorSeq, line.title);
      if (raw !== canonical) changed = true;
      out.push(canonical);
      continue;
    }
    if (line.kind === 'act' && line.actLabel) {
      const canonical = `══ ${line.actLabel} ══`;
      if (raw !== canonical) changed = true;
      out.push(canonical);
      continue;
    }
    out.push(raw);
  }

  if (!hasEvent || !changed) return content;
  return out.join('\n');
}

/** 导出前整理正文：统一事件 / 幕标题写法并重新编号（数据库原文不动） */
export function prepareOutlineTxtExportContent(content: string): string {
  return normalizeOutlineText(content);
}

/* ─────────────── v2 结构化文档：正文 + 小说设定 + 人物档案 ─────────────── */

/** v2 文件头（第一行非空内容必须与它完全一致才按结构化解析） */
export const OUTLINE_TXT_MAGIC = '# DeepSeek 大纲导出 v2';
/** 正文章节名 */
export const OUTLINE_TXT_BODY_SECTION = '大纲正文';
const SECTION_NAMES = ['书名', '类型', '主题', '主角简介', '世界观', '伏笔清单', '人物档案', OUTLINE_TXT_BODY_SECTION];

/** 人物档案（与手机端 `outline_records.characters` 的字段一一对应） */
export interface OutlineCharacterProfile {
  name: string;
  description: string;
  abilities: string;
  personality: string;
  isProtagonist: boolean;
}

/** 从 txt 里还原出来的小说设定 */
export interface OutlineDocumentMeta {
  title: string;
  genre: string;
  theme: string;
  protagonist: string;
  worldview: string;
  foreshadows: string;
  characters: OutlineCharacterProfile[];
}

/** 解析后的完整文档 */
export interface ParsedOutlineDocument {
  /** 是否 v2 结构化文件（false = 旧版纯正文） */
  structured: boolean;
  meta: OutlineDocumentMeta;
  /** 大纲正文（已 trim；网页端不重编号） */
  content: string;
  /** 是否识别到小说设定 */
  hasSettings: boolean;
  /** 弹窗展示的设定摘要，如「类型、世界观 · 人物档案 2 人」 */
  settingsSummary: string;
}

/** 导出时的入参 */
export interface OutlineDocumentInput {
  title: string;
  genre?: string;
  theme?: string;
  protagonist?: string;
  worldview?: string;
  foreshadows?: string;
  /** `outline_records.characters` 的 JSON 原文（坏了只丢人物档案） */
  charactersJson?: string;
  content: string;
}

function emptyMeta(): OutlineDocumentMeta {
  return {
    title: '',
    genre: '',
    theme: '',
    protagonist: '',
    worldview: '',
    foreshadows: '',
    characters: [],
  };
}

/** `outline_records.characters` JSON → 人物列表（空串 / 坏 JSON 都返回空数组） */
export function parseOutlineCharactersJson(raw: unknown): OutlineCharacterProfile[] {
  const text = String(raw ?? '').trim();
  if (!text) return [];
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return [];
  }
  if (!Array.isArray(data)) return [];
  const out: OutlineCharacterProfile[] = [];
  for (const item of data) {
    if (!item || typeof item !== 'object') continue;
    const row = item as Record<string, unknown>;
    out.push({
      name: String(row.name ?? ''),
      description: String(row.description ?? ''),
      abilities: String(row.abilities ?? ''),
      personality: String(row.personality ?? ''),
      isProtagonist: row.is_protagonist === true || row.is_protagonist === 1,
    });
  }
  return out;
}

/** 人物列表 → 可直接写 `outline_records.characters` 的 JSON（没有人物时为空串） */
export function charactersToDbJson(characters: OutlineCharacterProfile[]): string {
  if (!characters.length) return '';
  return JSON.stringify(
    characters.map((c) => ({
      name: c.name,
      description: c.description,
      abilities: c.abilities,
      personality: c.personality,
      is_protagonist: c.isProtagonist,
    })),
  );
}

/** 人物档案的可读段落（导出用；多行字段续行额外缩进 4 个空格） */
function renderCharacterSection(characters: OutlineCharacterProfile[]): string {
  const usable = characters.filter(
    (c) => c.name.trim() || c.description.trim() || c.abilities.trim() || c.personality.trim(),
  );
  if (!usable.length) return '';
  const lines: string[] = [];
  for (const c of usable) {
    lines.push(`- 姓名：${c.name.trim()}`);
    const addField = (label: string, value: string) => {
      const text = value.trim();
      if (!text) return;
      const parts = text.split('\n');
      lines.push(`  ${label}：${parts[0]}`);
      for (const part of parts.slice(1)) lines.push(`    ${part}`);
    };
    addField('描述', c.description);
    addField('能力', c.abilities);
    addField('性格', c.personality);
    lines.push(`  主角：${c.isProtagonist ? '是' : '否'}`);
  }
  return lines.join('\n');
}

/** 人物段落 → 人物列表（容错：字段顺序任意、缺「主角」当否） */
function parseCharacterSection(text: string): OutlineCharacterProfile[] {
  const trimmed = text.trim();
  if (!trimmed) return [];
  const result: OutlineCharacterProfile[] = [];
  let name = '';
  let description = '';
  let abilities = '';
  let personality = '';
  let isProtagonist = false;
  let currentField: '姓名' | '描述' | '能力' | '性格' | null = null;

  const flush = () => {
    if (!(name.trim() || description.trim() || abilities.trim() || personality.trim())) return;
    result.push({
      name: name.trim(),
      description: description.trim(),
      abilities: abilities.trim(),
      personality: personality.trim(),
      isProtagonist,
    });
  };
  const append = (value: string) => {
    switch (currentField) {
      case '姓名':
        name = name ? `${name}\n${value}` : value;
        break;
      case '描述':
        description = description ? `${description}\n${value}` : value;
        break;
      case '能力':
        abilities = abilities ? `${abilities}\n${value}` : value;
        break;
      case '性格':
        personality = personality ? `${personality}\n${value}` : value;
        break;
      default:
        break;
    }
  };

  for (const line of trimmed.split('\n')) {
    const textLine = line.replace(/\s+$/, '');
    if (!textLine.trim()) continue;
    const newCharacter = /^-\s*姓名\s*[:：]\s*(.*)$/.exec(textLine.trim());
    if (newCharacter) {
      flush();
      name = (newCharacter[1] ?? '').trim();
      description = '';
      abilities = '';
      personality = '';
      isProtagonist = false;
      currentField = '姓名';
      continue;
    }
    const field = /^[ \t]{0,2}(描述|能力|性格|主角|姓名)\s*[:：]\s?(.*)$/.exec(textLine);
    if (field) {
      const label = field[1];
      const value = (field[2] ?? '').trim();
      if (label === '主角') {
        isProtagonist = value === '是' || value.toLowerCase() === 'true';
        currentField = null;
      } else if (label === '姓名') {
        name = value;
        currentField = '姓名';
      } else {
        if (label === '描述') description = '';
        if (label === '能力') abilities = '';
        if (label === '性格') personality = '';
        currentField = label as '描述' | '能力' | '性格';
        append(value);
      }
      continue;
    }
    if (currentField && line.startsWith('    ')) {
      append(line.slice(4).replace(/\s+$/, ''));
    } else if (currentField) {
      append(textLine.trim());
    }
  }
  flush();
  return result;
}

/** 设定摘要（与手机端 `settingsSummary` 同口径） */
function buildSettingsSummary(meta: OutlineDocumentMeta): string {
  const labels: string[] = [];
  if (meta.genre.trim()) labels.push('类型');
  if (meta.theme.trim()) labels.push('主题');
  if (meta.protagonist.trim()) labels.push('主角简介');
  if (meta.worldview.trim()) labels.push('世界观');
  if (meta.foreshadows.trim()) labels.push('伏笔清单');
  const parts: string[] = [];
  if (labels.length) parts.push(labels.join('、'));
  if (meta.characters.length) parts.push(`人物档案 ${meta.characters.length} 人`);
  return parts.join(' · ');
}

function hasSettings(meta: OutlineDocumentMeta): boolean {
  return (
    !!meta.genre.trim() ||
    !!meta.theme.trim() ||
    !!meta.protagonist.trim() ||
    !!meta.worldview.trim() ||
    !!meta.foreshadows.trim() ||
    meta.characters.length > 0
  );
}

/**
 * 导出为 v2 结构化 txt 文本（不含 BOM；空字段整节省略）。
 * 与手机端 `renderOutlineTxtDocument` 输出格式完全一致。
 */
export function renderOutlineTxtDocument(input: OutlineDocumentInput): string {
  const lines: string[] = [OUTLINE_TXT_MAGIC, ''];
  const addSection = (name: string, value: string) => {
    const text = String(value ?? '').trim();
    if (!text) return;
    lines.push(`## ${name}`, text, '');
  };
  addSection('书名', input.title);
  addSection('类型', input.genre ?? '');
  addSection('主题', input.theme ?? '');
  addSection('主角简介', input.protagonist ?? '');
  addSection('世界观', input.worldview ?? '');
  addSection('伏笔清单', input.foreshadows ?? '');
  addSection('人物档案', renderCharacterSection(parseOutlineCharactersJson(input.charactersJson)));
  lines.push(`## ${OUTLINE_TXT_BODY_SECTION}`, '');
  const content = String(input.content ?? '');
  lines.push(content);
  if (!content.endsWith('\n')) lines.push('');
  return lines.join('\n');
}

/**
 * 解析导入的 txt 文本：
 * - 第一行非空内容为 v2 文件头 → 结构化解析；
 * - 否则按旧版「纯正文」兼容处理；
 * - 整份文件为空 → 抛错（弹窗提示「txt 文件是空的」）。
 */
export function parseOutlineTxtDocument(raw: string): ParsedOutlineDocument {
  let text = String(raw ?? '').replace(/^\uFEFF/, '');
  text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines = text.split('\n');
  const firstNonEmpty = lines.findIndex((line) => line.trim() !== '');
  if (firstNonEmpty < 0) throw new Error('txt 文件是空的');

  // 旧版纯正文：与以前完全一致
  if (lines[firstNonEmpty].trim() !== OUTLINE_TXT_MAGIC) {
    const content = normalizeImportedOutline(text);
    if (!content) throw new Error('txt 文件是空的');
    return {
      structured: false,
      meta: emptyMeta(),
      content,
      hasSettings: false,
      settingsSummary: '',
    };
  }

  const sections = new Map<string, string[]>();
  const bodyLines: string[] = [];
  let current: string | null = null;
  for (let i = firstNonEmpty + 1; i < lines.length; i++) {
    const line = lines[i];
    if (current === OUTLINE_TXT_BODY_SECTION) {
      bodyLines.push(line);
      continue;
    }
    const header = /^##\s+(.+?)\s*$/.exec(line);
    const name = header?.[1]?.trim();
    if (name && SECTION_NAMES.includes(name)) {
      current = name;
      sections.set(name, []);
      continue;
    }
    if (current) sections.get(current)?.push(line);
  }

  const section = (name: string) => (sections.get(name) ?? []).join('\n').trim();
  const firstLine = (value: string) => {
    for (const line of value.split('\n')) {
      const trimmed = line.trim();
      if (trimmed) return trimmed;
    }
    return '';
  };

  const meta: OutlineDocumentMeta = {
    title: firstLine(section('书名')),
    genre: section('类型'),
    theme: section('主题'),
    protagonist: section('主角简介'),
    worldview: section('世界观'),
    foreshadows: section('伏笔清单'),
    characters: parseCharacterSection(section('人物档案')),
  };
  const content = bodyLines.join('\n').trim();
  const document: ParsedOutlineDocument = {
    structured: true,
    meta,
    content,
    hasSettings: hasSettings(meta),
    settingsSummary: buildSettingsSummary(meta),
  };
  // 结构化文件但一个字都没有：按空文件提示
  if (!meta.title && !document.hasSettings && !content) {
    throw new Error('txt 文件是空的');
  }
  return document;
}

/** 导入标题：v2 书名章节 > 正文书名行 > 文件名 */
export function deriveOutlineTitleFromDocument(doc: ParsedOutlineDocument, fileName: string): string {
  if (doc.meta.title.trim()) return doc.meta.title.trim();
  return deriveOutlineTitle(doc.content, fileName);
}
