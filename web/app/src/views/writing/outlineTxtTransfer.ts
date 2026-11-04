/**
 * 大纲 txt 导出 / 导入的纯函数实现（不含任何 DOM 操作，方便单测与复用）。
 *
 * 行为规格见 reports/outline-txt-transfer-spec.md 第 2 节：
 * - 导出：UTF-8 + BOM、文件名《书名》大纲.txt、非法字符替换为 `_`；
 * - 导入：按 BOM 识别 UTF-8 / UTF-16LE / UTF-16BE，其余按 UTF-8 严格解码；
 *   BOM 由调用方按字节剥掉，这里只负责解码与文本规范化；
 * - 标题推导：正文首行「书名：《…》」优先，其次文件名，兜底「未命名大纲」；
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
const ACT_RE = new RegExp(`^\\s*${LEAD}第\\s*[一二三四五六七八九十百零0-9]+\\s*幕`);
/** 纯装饰行：只由 ═ / = / ＝ 与空白组成 */
const DECORATION_RE = /^[═=＝\s]+$/;

type OutlineLineKind = 'major' | 'minor' | 'act' | 'decoration' | 'other';

interface ClassifiedLine {
  kind: OutlineLineKind;
  /** 大事件 / 小事件的标题；其余类型为空串 */
  title: string;
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

  if (ACT_RE.test(trimmed)) return { kind: 'act', title: '' };
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
