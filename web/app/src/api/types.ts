/** api/types.ts —— 与服务端接口对应的类型定义 */

export type DbKey = 'deepseek' | 'novel';

export interface ColumnMeta {
  name: string;
  type: 'INTEGER' | 'REAL' | 'TEXT' | string;
  pk: boolean;
  notNull: boolean;
  /** 该列在 SQL 里有 DEFAULT，新增记录时可以留空 */
  hasDefault: boolean;
  autoIncrement: boolean;
  ref: string | null;
  appMissingOnCreate?: boolean;
}

export interface TableMeta {
  db: DbKey;
  name: string;
  label: string;
  module: string;
  singleton: boolean;
  columns: ColumnMeta[];
  searchColumns: string[];
}

export interface DatabaseMeta {
  key: DbKey;
  label: string;
  file: string;
  appVersion: number;
  tables: TableMeta[];
}

export interface Catalog {
  databases: DatabaseMeta[];
}

export interface HealthInfo {
  service: string;
  apiVersion: number;
  serverTime: number;
  uptimeSeconds: number;
  node: string;
  dataDir: string;
  authRequired: boolean;
  databases: { key: DbKey; file: string; appVersion: number; label: string }[];
}

export interface TableStats {
  count: number;
  updatedAt: number | null;
}

export interface Stats {
  databases: Record<DbKey, { label: string; file: string; appVersion: number; total: number; tables: Record<string, TableStats> }>;
  serverSeq: number;
}

export interface DeviceInfo {
  deviceId: string;
  name: string;
  platform: string;
  idBase: number;
  createdAt: number;
  lastSeenAt: number | null;
  rowsOwned: number;
  cursor: number;
  lastPushAt: number | null;
  lastPullAt: number | null;
}

export interface ConflictInfo {
  id: number;
  db: string;
  table: string;
  pk: number;
  incomingRev: number;
  serverRev: number;
  incomingDevice: string;
  detectedAt: number;
  resolution: string;
  detail: string;
}

export interface SyncOverview {
  serverSeq: number;
  devices: DeviceInfo[];
  recentConflicts: ConflictInfo[];
  stats: Stats['databases'];
}

export type Row = Record<string, unknown>;

export interface PagedMeta {
  page: number;
  pageSize: number;
  total: number;
  pages: number;
  truncated: boolean;
  db: string;
  table: string;
  label: string;
  filters: Record<string, string>;
}

export interface ImportReport {
  db: string;
  mode: string;
  deviceId: string;
  importedAt: number;
  uploadedBytes: number;
  sourceVersion: number;
  tables: Record<string, { read: number; written: number; unchanged: number; cleared: number }>;
  unknownTables: string[];
  unknownColumns: Record<string, string[]>;
  warnings: string[];
  totalRows: number;
  totalWritten: number;
  totalUnchanged: number;
}

export interface WriteResult {
  seq: number;
  rev: number;
  pk: number;
  unchanged: boolean;
  row?: Row;
  unknownColumns?: string[];
}

export interface DeleteResult {
  deleted: { table: string; pk: number; rev: number; seq: number }[];
  count: number;
  rootPk: number;
}

/** 模块标识 → 中文名（与 schema.js 的 module 字段对应） */
export const MODULE_LABELS: Record<string, string> = {
  settings: '设置',
  chat: '智能对话',
  novel_writing: '写小说',
  character_chat: '角色扮演',
  trpg: '跑团模拟器',
  novel_game: '小说游戏',
};

/** 把毫秒时间戳格式化成可读文本；兼容 ISO 字符串 */
export function formatTime(value: unknown): string {
  if (value === null || value === undefined || value === '') return '-';
  const date = typeof value === 'number' ? new Date(value) : new Date(String(value));
  if (Number.isNaN(date.getTime())) return String(value);
  const pad = (n: number) => String(n).padStart(2, '0');
  return (
    date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) +
    ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds())
  );
}
