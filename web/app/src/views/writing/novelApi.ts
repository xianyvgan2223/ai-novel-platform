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
