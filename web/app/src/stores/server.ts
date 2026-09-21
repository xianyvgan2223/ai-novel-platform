/**
 * stores/server.ts —— 全局服务状态（表目录 / 统计 / 同步总览）
 *
 * 表目录是「通用表浏览器」的数据来源：拿到 catalog 后，
 * 任意表都能自动渲染出表格、搜索框和编辑表单，新增表无需改前端。
 */
import { computed, ref } from 'vue';
import { defineStore } from 'pinia';
import { api } from '@/api';
import type { Catalog, DatabaseMeta, HealthInfo, Stats, SyncOverview, TableMeta } from '@/api';

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

  function tableMeta(db: string, table: string): TableMeta | undefined {
    return allTables.value.find((t) => t.db === db && t.name === table);
  }

  function rowCount(db: string, table: string): number {
    return stats.value?.databases?.[db as 'deepseek' | 'novel']?.tables?.[table]?.count ?? 0;
  }

  /** 首页统计卡要展示的几个关键指标 */
  const highlights = computed(() => {
    if (!stats.value) return [];
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
    return stats.value;
  }

  async function refreshOverview() {
    overview.value = await api.overview();
    return overview.value;
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
    allTables, groupedTables, highlights,
    tableMeta, rowCount,
    bootstrap, refreshHealth, refreshCatalog, refreshStats, refreshOverview,
  };
});
