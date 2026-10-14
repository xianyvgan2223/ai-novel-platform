/** api/index.ts —— 所有后端接口的集中入口（组件里只调用这里） */
import { del, download, get, getWithMeta, post, put, uploadBinary } from './client';
import type {
  Catalog, ConflictInfo, DbKey, DeleteResult, DeviceList, HealthInfo, ImportReport,
  PagedMeta, Row, Stats, SyncOverview, SyncRequestInfo, WriteResult,
} from './types';

export const api = {
  // ── 服务与元数据 ──
  health: () => get<HealthInfo>('/api/health'),
  catalog: () => get<Catalog>('/api/catalog'),
  /** 当前设备的数据概览（设备由 x-device-id 决定） */
  stats: () => get<Stats>('/api/stats'),

  // ── 通用数据 ──
  listRows: (db: DbKey, table: string, params: Record<string, unknown> = {}) =>
    getWithMeta<Row[], PagedMeta>('/api/data/' + db + '/' + table, params),
  getRow: (db: DbKey, table: string, pk: number) => get<Row>('/api/data/' + db + '/' + table + '/' + pk),
  createRow: (db: DbKey, table: string, row: Row) => post<WriteResult>('/api/data/' + db + '/' + table, row),
  updateRow: (db: DbKey, table: string, pk: number, row: Row) =>
    put<WriteResult>('/api/data/' + db + '/' + table + '/' + pk, row),
  deleteRow: (db: DbKey, table: string, pk: number) => del<DeleteResult>('/api/data/' + db + '/' + table + '/' + pk),

  // ── 文件导入导出（作用于当前设备的槽位）──
  importDb: (db: DbKey, file: File | Blob, mode: 'merge' | 'replace') =>
    uploadBinary<ImportReport>('/api/transfer/import?db=' + db + '&mode=' + mode, file),
  exportDb: (db: DbKey, sanitize: boolean) =>
    download('/api/transfer/export/' + db + '?sanitize=' + (sanitize ? '1' : '0'), db + '.db'),

  // ── 设备（每台设备一个独立数据槽位）──
  devices: () => get<DeviceList>('/api/sync/devices'),
  removeDevice: (deviceId: string) => del<{ deviceId: string; existed: boolean; purgedFiles: boolean }>(
    '/api/sync/devices/' + encodeURIComponent(deviceId),
  ),

  // ── 同步 ──
  overview: () => get<SyncOverview>('/api/sync/overview'),
  conflicts: (params: Record<string, unknown> = {}) => get<ConflictInfo[]>('/api/sync/conflicts', params),
  prune: () => post<{ deviceId: string; pruned: number; upTo: number }>('/api/sync/prune'),
  pull: (params: Record<string, unknown>) => get<Record<string, unknown>>('/api/sync/pull', params),
  push: (payload: Record<string, unknown>) => post<Record<string, unknown>>('/api/sync/push', payload),

  // ── 让手机去同步：网页发起 → 手机前台轮询领取 → 回报结果 ──
  requestPhoneSync: (targetDevice = '') =>
    post<SyncRequestInfo>('/api/sync/request', { targetDevice }),
  syncRequestStatus: (id: number) => get<SyncRequestInfo>('/api/sync/request/' + id),
};

export * from './types';
