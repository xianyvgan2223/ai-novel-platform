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
  /** 后端运行时版本（Java 版返回 JVM 版本） */
  node: string;
  dataDir: string;
  authRequired: boolean;
  /** 数据隔离方式：per-device = 每台设备一个独立数据槽位 */
  isolation?: string;
  deviceCount?: number;
  devices?: { deviceId: string; name: string; lastSeenAt: number | null }[];
  /** v1 遗留的共享库文件名（还在的话） */
  legacyFiles?: string[];
  databases: { key: DbKey; file: string; appVersion: number; label: string }[];
}

export interface TableStats {
  count: number;
  updatedAt: number | null;
}

export interface Stats {
  /** 当前正在查看哪台设备的槽位 */
  deviceId: string;
  deviceExists: boolean;
  deviceSeq: number;
  /** 设备清单版本号，变了说明有新设备连上来 */
  revision: number;
  devices: DeviceInfo[];
  databases: Record<DbKey, { label: string; file: string; appVersion: number; total: number; tables: Record<string, TableStats> }>;
}

export interface DeviceInfo {
  deviceId: string;
  name: string;
  platform: string;
  idBase: number;
  /** 该设备数据在服务端的目录名（devices/<scopeDir>/） */
  scopeDir: string;
  createdAt: number;
  lastSeenAt: number | null;
  /** 该设备槽位里的总行数（只有设备清单接口会算） */
  rowsOwned?: number;
  /** 按「库.表」统计的行数 */
  rowCounts?: Record<string, number>;
  conflicts?: number;
  cursor: number;
  lastPushAt: number | null;
  lastPullAt: number | null;
}

export interface DeviceList {
  activeDeviceId: string;
  devices: DeviceInfo[];
  totalRows: number;
  revision: number;
  /** v1 时期的共享库文件（还存在的话），可手动上传导入到某台设备 */
  legacyFiles?: { file: string; bytes: number }[];
}

export interface ConflictInfo {
  id: number;
  deviceId: string;
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
  deviceId: string;
  deviceExists: boolean;
  deviceSeq: number;
  revision: number;
  devices: DeviceInfo[];
  recentConflicts: ConflictInfo[];
  allConflicts: number;
  stats: Stats['databases'] | null;
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
  /** 数据实际落到了哪台设备的槽位 */
  deviceId: string;
  targetDevice?: string;
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

/** 「请手机同步」请求的状态 */
export interface SyncRequestInfo {
  id: number;
  targetDevice: string;
  requestedBy: string;
  requestedAt: number;
  /** pending=等待手机确认 / claimed=手机已领取 / done=完成 / failed=失败 / rejected=手机拒绝 */
  status: 'pending' | 'claimed' | 'done' | 'failed' | 'rejected';
  claimedAt: number | null;
  finishedAt: number | null;
  result: string;
  /** 手机上报的实时进度 */
  progress: {
    message: string;
    current: number | null;
    total: number | null;
    updatedAt: number;
  } | null;
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

/** ── 写作优化 ── */

export type WritingAction = 'polish' | 'deai' | 'expand' | 'condense' | 'continue' | 'structure';

export type WritingStyle = 'original' | 'plain' | 'literary' | 'restrained' | 'hot' | 'suspense' | 'ancient';

export type WritingStrength = 'light' | 'medium' | 'strong';

export interface OptimizePayload {
  text: string;
  actions: WritingAction[];
  style?: WritingStyle;
  strength?: WritingStrength;
  /** 额外要求，例如「删掉所有比喻」 */
  extra?: string;
}

export type DrawKind = 'short' | 'outline';

export interface DrawPayload {
  kind: DrawKind;
  genre?: string;
  keywords?: string;
  perspective?: string;
  count?: number;
  extra?: string;
}

export interface WritingCardField {
  label: string;
  value: string;
}

export interface WritingCard {
  title: string;
  logline: string;
  fields: WritingCardField[];
}

export interface DrawResult {
  kind: DrawKind;
  cards: WritingCard[];
}

/** 写作优化流式事件的结束信息 */
export interface OptimizeDoneInfo {
  chars?: number;
  elapsedMs?: number;
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
