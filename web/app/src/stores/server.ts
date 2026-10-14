/**
 * stores/server.ts —— 全局服务状态（设备 / 表目录 / 统计 / 同步总览）
 *
 * 数据是「按设备隔离」的：服务端为每台设备保存一份独立的库与变更日志。
 * 当前看哪台设备由 stores/device.ts 的 activeDeviceId 决定（请求头 x-device-id）。
 * 切换设备时这里会重置统计并递增 deviceEpoch，各页面 watch 它重新取数。
 *
 * 表目录是「通用表浏览器」的数据来源：拿到 catalog 后，
 * 任意表都能自动渲染出表格、搜索框和编辑表单，新增表无需改前端。
 */
import { computed, ref } from 'vue';
import { defineStore } from 'pinia';
import { ElMessage } from 'element-plus';
import { api } from '@/api';
import type { Catalog, DatabaseMeta, DeviceInfo, HealthInfo, Stats, SyncOverview, TableMeta } from '@/api';
import { activeDeviceId, bumpDeviceEpoch, setActiveDevice, WEB_DEVICE_ID } from './device';

export const useServerStore = defineStore('server', () => {
  const health = ref<HealthInfo | null>(null);
  const catalog = ref<Catalog | null>(null);
  const stats = ref<Stats | null>(null);
  const overview = ref<SyncOverview | null>(null);
  const loading = ref(false);
  const online = ref(false);
  const lastError = ref('');

  /** 扁平化后的表列表，方便下拉选择与快速定位 */
  const allTables = computed<TableMeta[]>(() => catalog.value?.databases.flatMap((d) => d.tables) ?? []);

  /** 按库 + 模块分组的表，用于分组下拉框 */
  const groupedTables = computed(() => {
    const out: { db: DatabaseMeta; modules: { module: string; tables: TableMeta[] }[] }[] = [];
    for (const db of catalog.value?.databases ?? []) {
      const byModule = new Map<string, TableMeta[]>();
      for (const table of db.tables) {
        if (!byModule.has(table.module)) byModule.set(table.module, []);
        byModule.get(table.module)!.push(table);
      }
      out.push({ db, modules: [...byModule].map(([module, tables]) => ({ module, tables })) });
    }
    return out;
  });

  /** 设备下拉框的数据源；「同步与备份」页也用它 */
  const devices = computed<DeviceInfo[]>(() => stats.value?.devices ?? overview.value?.devices ?? []);

  /** 当前设备的展示名（给顶栏用） */
  const activeDevice = computed<DeviceInfo | undefined>(() =>
    devices.value.find((d) => d.deviceId === activeDeviceId.value),
  );

  const activeDeviceLabel = computed(() => {
    const device = activeDevice.value;
    if (!device) return activeDeviceId.value;
    const rows = device.rowsOwned ?? 0;
    return device.name && device.name !== device.deviceId
      ? device.name + '（' + device.deviceId + '）'
      : device.deviceId + (rows ? ' · ' + rows + ' 行' : '');
  });

  function tableMeta(db: string, table: string): TableMeta | undefined {
    return allTables.value.find((t) => t.db === db && t.name === table);
  }

  function rowCount(db: string, table: string): number {
    return stats.value?.databases?.[db as 'deepseek' | 'novel']?.tables?.[table]?.count ?? 0;
  }

  /** 首页统计卡要展示的几个关键指标 */
  const highlights = computed(() => {
    if (!stats.value?.databases) return [];
    return [
      { label: '对话会话', value: rowCount('deepseek', 'chat_sessions'), extra: 'chat_sessions' },
      { label: '对话消息', value: rowCount('deepseek', 'chat_messages'), extra: 'chat_messages' },
      { label: '小说作品', value: rowCount('deepseek', 'outline_records'), extra: 'outline_records' },
      { label: '已生成章节', value: rowCount('deepseek', 'outline_chapters'), extra: 'outline_chapters' },
      { label: '角色扮演会话', value: rowCount('deepseek', 'character_chat_sessions'), extra: 'character_chat_sessions' },
      { label: '世界书条目', value: rowCount('deepseek', 'world_info_entries'), extra: 'world_info_entries' },
      { label: '跑团战役', value: rowCount('deepseek', 'trpg_campaigns'), extra: 'trpg_campaigns' },
      { label: '小说游戏角色', value: rowCount('novel', 'character_table'), extra: 'novel.character_table' },
    ];
  });

  async function refreshHealth() {
    try {
      health.value = await api.health();
      online.value = true;
      lastError.value = '';
    } catch (err) {
      online.value = false;
      health.value = null;
      lastError.value = err instanceof Error ? err.message : String(err);
    }
  }

  async function refreshCatalog() {
    if (catalog.value) return catalog.value;
    catalog.value = await api.catalog();
    return catalog.value;
  }

  async function refreshStats() {
    stats.value = await api.stats();
    reconcileActiveDevice();
    return stats.value;
  }

  async function refreshOverview() {
    overview.value = await api.overview();
    reconcileActiveDevice();
    return overview.value;
  }

  /**
   * 选中的设备在服务端不存在时（比如数据被删了、或换了台服务端），
   * 退回 Web 控制台，避免每个请求都报 404。
   */
  function reconcileActiveDevice() {
    const list = devices.value;
    if (!list.length) return;
    if (list.some((d) => d.deviceId === activeDeviceId.value)) return;
    const fallback = list.some((d) => d.deviceId === WEB_DEVICE_ID) ? WEB_DEVICE_ID : list[0].deviceId;
    setActiveDevice(fallback);
    bumpDeviceEpoch();
  }

  /**
   * 切换正在查看的设备 —— 所有数据都换成那台设备的。
   * @param silent 不弹提示（初始化时用）
   */
  async function switchDevice(deviceId: string, { silent = false } = {}) {
    if (deviceId === activeDeviceId.value) return;
    setActiveDevice(deviceId);
    bumpDeviceEpoch();
    loading.value = true;
    try {
      // 统计 / 总览 / 冲突都跟着设备走，切完立刻重取
      await Promise.all([refreshStats(), refreshOverview().catch(() => undefined)]);
      if (!silent) ElMessage.success('已切换到设备 ' + deviceId);
    } catch (err) {
      if (!silent) ElMessage.error(err instanceof Error ? err.message : String(err));
    } finally {
      loading.value = false;
    }
  }

  /** 首次进入或手动刷新时调用 */
  async function bootstrap() {
    loading.value = true;
    try {
      await refreshHealth();
      if (online.value) await Promise.all([refreshCatalog(), refreshStats()]);
    } finally {
      loading.value = false;
    }
  }

  return {
    health, catalog, stats, overview, loading, online, lastError,
    allTables, groupedTables, highlights, devices, activeDevice, activeDeviceLabel,
    tableMeta, rowCount,
    bootstrap, switchDevice, refreshHealth, refreshCatalog, refreshStats, refreshOverview,
  };
});
