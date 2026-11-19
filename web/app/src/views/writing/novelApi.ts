/** 小说创作页面共用的小工具：加载作品 / 章节、保存章节 */
import { api } from '@/api';
import type { Row } from '@/api';

export const isMinor = (row: Row | null | undefined): boolean =>
  String(row?.event_type ?? '') === 'minor';

export const isMajor = (row: Row | null | undefined): boolean =>
  String(row?.event_type ?? '') === 'major';

export async function loadOutline(id: number): Promise<Row> {
  return api.getRow('deepseek', 'outline_records', id);
}

export async function loadOutlines(): Promise<Row[]> {
  const res = await api.listRows('deepseek', 'outline_records', { page: 1, pageSize: 200 });
  return res.data;
}

export async function loadChapters(outlineId: number): Promise<Row[]> {
  const res = await api.listRows('deepseek', 'outline_chapters', {
    outline_id: outlineId,
    page: 1,
    pageSize: 1000,
    orderBy: 'event_index',
    dir: 'asc',
  });
  return res.data;
}

export async function loadAllChapters(): Promise<Row[]> {
  const res = await api.listRows('deepseek', 'outline_chapters', {
    page: 1,
    pageSize: 1000,
    orderBy: 'event_index',
    dir: 'asc',
  });
  return res.data;
}

export async function saveChapterContent(id: number, content: string): Promise<void> {
  const now = new Date().toISOString();
  await api.updateRow('deepseek', 'outline_chapters', id, {
    content,
    status: 'completed',
    updated_at: now,
  });
}

/** 一个事件在界面上的规范编号：大事件全篇连续，小事件在每个大事件内部重新计数 */
export interface EventNumber {
  kind: 'major' | 'minor';
  number: number;
}

/**
 * 按列表顺序算出每个事件的显示编号（与大纲正文里的「大事件N / 小事件N」一致）。
 * 不能用 event_index：它是所有事件的连续序号，大事件也占号，直接显示会跳号。
 */
export function eventNumbers(chapters: Row[]): Map<number, EventNumber> {
  const map = new Map<number, EventNumber>();
  let majorSeq = 0;
  let minorSeq = 0;
  for (const row of chapters) {
    if (isMajor(row)) {
      majorSeq += 1;
      minorSeq = 0;
      map.set(Number(row.id), { kind: 'major', number: majorSeq });
    } else {
      minorSeq += 1;
      map.set(Number(row.id), { kind: 'minor', number: minorSeq });
    }
  }
  return map;
}

/** 这一篇正文是否已经有内容（与 statsOf 的「已写」口径一致） */
export function hasContent(row: Row | null | undefined): boolean {
  return String(row?.content ?? '').trim().length > 0;
}

/** 正文 / 概要的字数：去掉首尾空白后统计字符数 */
export function charsOf(value: unknown): number {
  return String(value ?? '').trim().length;
}

/**
 * 列表接口会把超过上限的文本截成「前 N 字…（共 X 字，打开详情查看全文）」。
 * 查看类页面据此拆出预览正文与真实字数：预览用于列表，完整内容再按 id 单独取。
 */
export function splitTruncatedText(value: unknown): { text: string; length: number; truncated: boolean } {
  const raw = String(value ?? '');
  const match = raw.match(/…（共 (\d+) 字，打开详情查看全文）$/);
  if (!match) return { text: raw, length: raw.length, truncated: false };
  const preview = raw.slice(0, raw.length - match[0].length);
  return { text: preview, length: Number(match[1]) || raw.length, truncated: true };
}

/** 列表行里的真实字数（被截断时取「共 X 字」里的 X） */
export function trueLengthOf(value: unknown): number {
  return splitTruncatedText(value).length;
}

export interface OutlineStats {
  total: number;
  minor: number;
  written: number;
}

export function statsOf(chapters: Row[]): OutlineStats {
  const minorRows = chapters.filter((row) => isMinor(row));
  const written = minorRows.filter((row) => String(row.status) === 'completed' || String(row.content ?? '').trim()).length;
  return { total: chapters.length, minor: minorRows.length, written };
}

export function formatCount(value: unknown): string {
  const number = Number(value ?? 0);
  return Number.isFinite(number) ? String(number) : '0';
}
