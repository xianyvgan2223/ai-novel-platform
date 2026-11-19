/**
 * 轻量 Markdown 解析：只覆盖 Agent / 聊天回复里常见的语法。
 *
 * 刻意不生成 HTML、不执行任何用户内容：解析结果交给 Vue 用 VNode 渲染，
 * 原始 HTML 标签只会被当成普通文本显示，不存在 v-html 的 XSS 风险。
 */

export type InlineKind = 'text' | 'bold' | 'italic' | 'code' | 'link' | 'strike';

export interface Inline {
  t: InlineKind;
  v: string;
  href?: string;
}

export type Align = 'left' | 'center' | 'right' | null;

export interface Block {
  k: 'p' | 'h' | 'code' | 'ul' | 'ol' | 'table' | 'quote' | 'hr';
  /** 段落 / 引用里的每一行（行内标记已解析） */
  lines?: Inline[][];
  /** 标题纯文本、代码块内容 */
  text?: string;
  /** 标题级别 1~4、代码语言 */
  level?: number;
  lang?: string;
  /** 列表项 / 引用行 */
  items?: Inline[][];
  /** 表格表头、表体与列对齐 */
  header?: Inline[][];
  rows?: Inline[][][];
  align?: Align[];
}

const FENCE = /^\s*(`{3,}|~{3,})/;
const HEADING = /^(#{1,6})\s+(.*)$/;
const HR = /^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/;
const BULLET = /^\s*[-*+]\s+(.*)$/;
const ORDERED = /^\s*\d+[.)]\s+(.*)$/;
const TABLE_SEPARATOR_CELL = /^:?-{3,}:?$/;
const SAFE_HREF = /^(https?:\/\/|mailto:)/i;

/** 只允许 http(s)/mailto 链接，其它（如 javascript:）按普通文本显示。 */
function isSafeHref(url: string): boolean {
  return SAFE_HREF.test(url.trim());
}

function pushText(out: Inline[], text: string): void {
  if (!text) return;
  out.push({ t: 'text', v: text });
}

/** 行内解析：加粗、斜体、删除线、行内代码、链接。 */
export function parseInline(line: string): Inline[] {
  const out: Inline[] = [];
  let text = '';
  let i = 0;

  const flush = () => {
    pushText(out, text);
    text = '';
  };

  while (i < line.length) {
    const rest = line.slice(i);
    let m: RegExpExecArray | null;

    if ((m = /^\*\*([^*]+)\*\*/.exec(rest))) {
      flush();
      out.push({ t: 'bold', v: m[1] });
      i += m[0].length;
      continue;
    }
    if ((m = /^~~([^~]+)~~/.exec(rest))) {
      flush();
      out.push({ t: 'strike', v: m[1] });
      i += m[0].length;
      continue;
    }
    if ((m = /^`([^`]+)`/.exec(rest))) {
      flush();
      out.push({ t: 'code', v: m[1] });
      i += m[0].length;
      continue;
    }
    if ((m = /^\[([^\]]+)\]\(([^)\s]+)\)/.exec(rest))) {
      if (isSafeHref(m[2])) {
        flush();
        out.push({ t: 'link', v: m[1], href: m[2].trim() });
        i += m[0].length;
        continue;
      }
      // 不安全链接：按普通文本显示
      text += line[i];
      i += 1;
      continue;
    }
    if ((m = /^\*([^*\n]+)\*/.exec(rest))) {
      flush();
      out.push({ t: 'italic', v: m[1] });
      i += m[0].length;
      continue;
    }
    if ((m = /^_([^_\n]+)_/.exec(rest))) {
      const prev = i > 0 ? line[i - 1] : '';
      const next = line[i + m[0].length] ?? '';
      // 避免把 some_var_name 这类标识符中间的下划线当成斜体
      if (!/[A-Za-z0-9]/.test(prev) && !/[A-Za-z0-9]/.test(next)) {
        flush();
        out.push({ t: 'italic', v: m[1] });
        i += m[0].length;
        continue;
      }
    }

    text += line[i];
    i += 1;
  }

  flush();
  return out.length ? out : [{ t: 'text', v: '' }];
}

/** 按未转义的 | 拆分表格行；两侧的边框竖线忽略。 */
function splitTableRow(line: string): string[] {
  let row = line.trim();
  if (row.startsWith('|')) row = row.slice(1);
  if (row.endsWith('|')) row = row.slice(0, -1);

  const cells: string[] = [];
  let current = '';
  for (let i = 0; i < row.length; i += 1) {
    const ch = row[i];
    if (ch === '\\' && row[i + 1] === '|') {
      current += '|';
      i += 1;
    } else if (ch === '|') {
      cells.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  cells.push(current.trim());
  return cells;
}

function tableAlign(cell: string): Align {
  const value = cell.trim();
  const left = value.startsWith(':');
  const right = value.endsWith(':');
  if (left && right) return 'center';
  if (right) return 'right';
  if (left) return 'left';
  return null;
}

function isTableStart(lines: string[], index: number): boolean {
  if (index + 1 >= lines.length) return false;
  if (!lines[index].includes('|') || !lines[index + 1].includes('-')) {
    return false;
  }
  const header = splitTableRow(lines[index]);
  const separator = splitTableRow(lines[index + 1]);
  if (header.length === 0 || separator.length !== header.length) {
    return false;
  }
  return separator.every((cell) => TABLE_SEPARATOR_CELL.test(cell.trim()));
}

function isTableBodyLine(line: string): boolean {
  const value = line.trim();
  if (!value || !value.includes('|')) return false;
  if (FENCE.test(value) || HR.test(value)) return false;
  return true;
}

/** 解析整段文本。未闭合的代码块会一直渲染到结尾，避免流式输出时闪烁。 */
export function parseMarkdown(src: string): Block[] {
  const lines = String(src ?? '').split(/\r?\n/);
  const blocks: Block[] = [];
  let para: Inline[][] = [];
  let list: { kind: 'ul' | 'ol'; items: Inline[][] } | null = null;
  let i = 0;

  const flushPara = () => {
    if (!para.length) return;
    blocks.push({ k: 'p', lines: para });
    para = [];
  };
  const flushList = () => {
    if (!list) return;
    blocks.push(
      list.kind === 'ul'
        ? { k: 'ul', items: list.items }
        : { k: 'ol', items: list.items },
    );
    list = null;
  };

  while (i < lines.length) {
    const line = lines[i];

    const fence = FENCE.exec(line);
    if (fence) {
      flushPara();
      flushList();
      const marker = fence[1][0];
      const closing = new RegExp('^\\s*' + marker + '{3,}\\s*$');
      const lang = line.replace(FENCE, '').trim();
      const code: string[] = [];
      i += 1;
      while (i < lines.length && !closing.test(lines[i])) {
        code.push(lines[i]);
        i += 1;
      }
      if (i < lines.length) i += 1;
      blocks.push({ k: 'code', lang, text: code.join('\n') });
      continue;
    }

    if (!line.trim()) {
      flushPara();
      flushList();
      i += 1;
      continue;
    }

    if (isTableStart(lines, i)) {
      flushPara();
      flushList();
      const header = splitTableRow(line);
      const separator = splitTableRow(lines[i + 1]);
      const align = separator.map(tableAlign);
      i += 2;
      const rows: Inline[][][] = [];
      while (i < lines.length && isTableBodyLine(lines[i])) {
        const cells = splitTableRow(lines[i]);
        rows.push(cells.map(parseInline));
        i += 1;
      }
      blocks.push({
        k: 'table',
        header: header.map(parseInline),
        rows,
        align,
      });
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      flushPara();
      flushList();
      blocks.push({
        k: 'h',
        level: heading[1].length,
        text: heading[2].trim(),
      });
      i += 1;
      continue;
    }

    if (HR.test(line)) {
      flushPara();
      flushList();
      blocks.push({ k: 'hr' });
      i += 1;
      continue;
    }

    if (/^\s*>/.test(line)) {
      flushPara();
      flushList();
      const quote: Inline[][] = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) {
        const content = lines[i].replace(/^\s*>\s?/, '');
        quote.push(parseInline(content));
        i += 1;
      }
      blocks.push({ k: 'quote', lines: quote });
      continue;
    }

    const bullet = BULLET.exec(line);
    if (bullet) {
      flushPara();
      if (!list || list.kind !== 'ul') {
        flushList();
        list = { kind: 'ul', items: [] };
      }
      list.items.push(parseInline(bullet[1]));
      i += 1;
      continue;
    }

    const ordered = ORDERED.exec(line);
    if (ordered) {
      flushPara();
      if (!list || list.kind !== 'ol') {
        flushList();
        list = { kind: 'ol', items: [] };
      }
      list.items.push(parseInline(ordered[1]));
      i += 1;
      continue;
    }

    flushList();
    para.push(parseInline(line));
    i += 1;
  }

  flushPara();
  flushList();
  return blocks;
}
