import type { OutlineAct, OutlineEvent } from '@/api';
import type { GeneratedChapterRow } from '@/api';

const ACT_RE = /^[═=＝\s]*(第[一二三四五六七八九十百0-9]+幕(?:[：:][^═=＝]*)?)[═=＝\s]*$/;
const MAJOR_RE = /^(?:[═=＝\s]*)?大事件\s*([0-9]+)\s*[：:]\s*(.*?)\s*[═=＝\s]*$/;
const MINOR_RE = /^(?:[○◦◯oO]\s*)?小事件\s*([0-9]+)\s*[：:]\s*(.*)$/;

function cleanTitle(value: string): string {
  let text = value.trim();
  text = text.replace(/^[○◦◯oO]\s*/, '');
  for (let i = 0; i < 3; i++) {
    text = text.replace(/^[\s═=＝*_]+/, '').replace(/[\s═=＝*_]+$/, '');
    text = text.replace(/^(?:大事件|小事件|Major|事件)\s*\d+\s*[：:]\s*/, '');
  }
  return text.trim();
}

function cleanSummary(lines: string[]): string {
  return lines.join('\n').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

/** 把检查点里用户编辑的粗骨架/大事件文本解析回结构化 acts。 */
export function parseActs(text: string): OutlineAct[] {
  const acts: OutlineAct[] = [];
  let currentAct: OutlineAct | null = null;
  let currentEvent: OutlineEvent | null = null;
  let summary: string[] = [];

  const flushEvent = () => {
    if (!currentEvent) return;
    currentEvent.summary = cleanSummary(summary);
    if (currentAct) currentAct.events.push(currentEvent);
    currentEvent = null;
    summary = [];
  };

  const ensureAct = (name: string) => {
    flushEvent();
    currentAct = { name: name.trim() || `第${acts.length + 1}幕`, events: [] };
    acts.push(currentAct);
  };

  for (const rawLine of text.replace(/\r\n/g, '\n').split('\n')) {
    const line = rawLine.trim();
    if (!line) {
      if (currentEvent) summary.push('');
      continue;
    }
    const actMatch = line.match(ACT_RE);
    if (actMatch) {
      ensureAct(actMatch[1]);
      continue;
    }
    const majorMatch = line.match(MAJOR_RE);
    if (majorMatch) {
      if (!currentAct) ensureAct('第一幕');
      flushEvent();
      currentEvent = { title: cleanTitle(majorMatch[2]), summary: '' };
      continue;
    }
    if (MINOR_RE.test(line)) {
      continue;
    }
    if (currentEvent) summary.push(rawLine.trimEnd());
  }
  flushEvent();
  return acts.filter((act) => act.events.length > 0);
}

/** 按移动端固定格式渲染三幕骨架/大事件检查点文本。 */
export function renderActs(acts: OutlineAct[], withNumbers = true): string {
  const fallback = ['第一幕：开端', '第二幕：发展', '第三幕：高潮&结局'];
  const out: string[] = [];
  let index = 0;
  acts.forEach((act, actIndex) => {
    const name = act.name?.trim() || fallback[actIndex] || `第${actIndex + 1}幕`;
    out.push(`══ ${name} ══`, '');
    for (const event of act.events) {
      index += 1;
      out.push(withNumbers ? `══ 大事件${index}：${cleanTitle(event.title)} ══` : cleanTitle(event.title));
      out.push(event.summary?.trim() || '（待补充定位）');
      out.push('');
    }
  });
  return out.join('\n').trim();
}

/** 从最终大纲全文解析出可落库的大/小事件行。 */
export function parseChapters(text: string): GeneratedChapterRow[] {
  const rows: GeneratedChapterRow[] = [];
  let currentMajor: GeneratedChapterRow | null = null;
  let currentMinor: GeneratedChapterRow | null = null;
  let summary: string[] = [];
  let index = 0;

  const flush = () => {
    const target = currentMinor ?? currentMajor;
    if (target) target.summary = cleanSummary(summary);
    summary = [];
  };

  for (const rawLine of text.replace(/\r\n/g, '\n').split('\n')) {
    const line = rawLine.trim();
    const major = line.match(MAJOR_RE);
    if (major) {
      flush();
      index += 1;
      currentMinor = null;
      currentMajor = {
        index,
        type: 'major',
        title: cleanTitle(major[2]),
        summary: '',
      };
      rows.push(currentMajor);
      continue;
    }
    const minor = line.match(MINOR_RE);
    if (minor) {
      flush();
      index += 1;
      currentMinor = {
        index,
        type: 'minor',
        title: cleanTitle(minor[2]),
        summary: '',
      };
      rows.push(currentMinor);
      continue;
    }
    if (ACT_RE.test(line)) {
      flush();
      currentMinor = null;
      currentMajor = null;
      continue;
    }
    if (currentMinor || currentMajor) {
      if (line) summary.push(line);
    }
  }
  flush();
  return rows;
}

/** 从粗骨架里计算大事件数量。 */
export function countEvents(acts: OutlineAct[]): number {
  return acts.reduce((sum, act) => sum + act.events.length, 0);
}
